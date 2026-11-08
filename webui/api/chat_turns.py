"""Starting one agent turn on a chat session: claim the session, register its stream, run the agent on a worker thread. Used by HTTP chat, voice, Agents and goal kickoffs."""
import logging
import threading
import time
import uuid

from api.config import PENDING_GOAL_CONTINUATION, STREAMS, STREAMS_LOCK, STREAM_GOAL_RELATED, _get_session_agent_lock, create_stream_channel, get_webui_session_save_mode
from api.models import get_session, title_from
from api.session_events import SESSION_EVENTS
from api.session_model import resolve_session_model_state
from api.streaming import _materialize_pending_user_turn_before_error, _run_agent_streaming
from api.turn_options import TurnOptions
from api.workspace import get_last_workspace, resolve_trusted_workspace, set_last_workspace

logger = logging.getLogger(__name__)


def clear_stale_stream_state(session) -> bool:
    """Clear persisted streaming flags when the in-memory stream no longer exists.

    A server restart or worker crash can leave active_stream_id/pending_* in the
    session JSON while STREAMS is empty. The frontend then keeps reconnecting to
    a dead stream and shows a permanent running/thinking state.

    SAFETY (#1558): If ``session`` was loaded with ``metadata_only=True``, its
    ``messages`` array is empty by design and calling ``save()`` would
    atomically overwrite the on-disk JSON, wiping the conversation. In that
    case we re-load the full session before mutating, so the persisted
    write carries the real messages forward.
    """
    stream_id = getattr(session, "active_stream_id", None)
    if not stream_id:
        return False
    with STREAMS_LOCK:
        stream_alive = stream_id in STREAMS
    if stream_alive:
        return False

    # ── #1558 P0 safety: if we were handed a metadata-only stub, reload the
    # full session before touching persisted state. The original
    # metadata-only object is left untouched so the caller's read path is
    # unaffected.
    original_stub = session  # SHOULD-FIX #1 (Opus): keep reference so we can
                             # patch the caller's in-memory copy after a
                             # successful clear, avoiding one ghost SSE
                             # reconnect on the very next /api/session GET.
    if getattr(session, "_loaded_metadata_only", False):
        try:
            from api.models import get_session as _get_session
            session = _get_session(session.session_id, metadata_only=False)
        except Exception:
            # If we cannot upgrade to a full load (file gone, decode error,
            # etc.) bail without clearing — better to leave a stale
            # active_stream_id than to wipe the conversation.
            logger.warning(
                "clear_stale_stream_state: refused to clear stale stream %s "
                "for session %s — full reload failed and we will not save a "
                "metadata-only stub. See #1558.",
                stream_id, getattr(session, "session_id", "?"),
            )
            return False
        if session is None:
            return False
        # The full-load path may have already repaired stale pending fields
        # via _repair_stale_pending(); only re-assert if still set.
        if not getattr(session, "active_stream_id", None):
            # Patch the caller's stub so its read path also sees the cleared
            # field (matches the Opus SHOULD-FIX #1 — without this, /api/session
            # would briefly return the stale active_stream_id and the frontend
            # would attempt one ghost SSE reconnect before recovering).
            try:
                original_stub.active_stream_id = None
                if hasattr(original_stub, "pending_user_message"):
                    original_stub.pending_user_message = None
                if hasattr(original_stub, "pending_attachments"):
                    original_stub.pending_attachments = []
                if hasattr(original_stub, "pending_started_at"):
                    original_stub.pending_started_at = None
            except Exception:
                pass
            return False

    # ── #1533 race fix: acquire the per-session lock and re-read
    # active_stream_id under it. A concurrent chat_start may have already
    # registered a new stream after our STREAMS_LOCK check above; in that
    # case we must NOT clobber its session.active_stream_id.
    with _get_session_agent_lock(session.session_id):
        if getattr(session, "active_stream_id", None) != stream_id:
            return False
        if getattr(session, "pending_user_message", None):
            try:
                from api.models import _apply_core_sync_or_error_marker, _get_profile_home
                profile_home = _get_profile_home(getattr(session, "profile", None))
                core_path = profile_home / "sessions" / f"session_{session.session_id}.json"
                repaired = _apply_core_sync_or_error_marker(
                    session,
                    core_path,
                    stream_id_for_recheck=stream_id,
                    touch_updated_at=False,
                )
            except Exception:
                logger.exception(
                    "clear_stale_stream_state: failed to repair stale pending stream %s "
                    "for session %s",
                    stream_id, getattr(session, "session_id", "?"),
                )
                repaired = False
            if repaired:
                if original_stub is not session:
                    try:
                        original_stub.active_stream_id = None
                        if hasattr(original_stub, "pending_user_message"):
                            original_stub.pending_user_message = None
                        if hasattr(original_stub, "pending_attachments"):
                            original_stub.pending_attachments = []
                        if hasattr(original_stub, "pending_started_at"):
                            original_stub.pending_started_at = None
                    except Exception:
                        pass
                return True
            if getattr(session, "active_stream_id", None) != stream_id:
                return False
        _materialize_pending_user_turn_before_error(session)
        session.active_stream_id = None
        if hasattr(session, "pending_user_message"):
            session.pending_user_message = None
        if hasattr(session, "pending_attachments"):
            session.pending_attachments = []
        if hasattr(session, "pending_started_at"):
            session.pending_started_at = None
        try:
            # Runtime cleanup is not user activity; do not bubble old sessions
            # to the top of the sidebar just because a stale stream flag was
            # repaired during a read/list path.
            session.save(touch_updated_at=False)
        except Exception:
            logger.exception(
                "clear_stale_stream_state: save() failed for session %s",
                getattr(session, "session_id", "?"),
            )
    # Patch the caller's stub (if different from the full-load object) so
    # its in-memory active_stream_id matches what just got persisted.
    if original_stub is not session:
        try:
            original_stub.active_stream_id = None
            if hasattr(original_stub, "pending_user_message"):
                original_stub.pending_user_message = None
            if hasattr(original_stub, "pending_attachments"):
                original_stub.pending_attachments = []
            if hasattr(original_stub, "pending_started_at"):
                original_stub.pending_started_at = None
        except Exception:
            pass
    return True


def _checkpoint_user_message_for_eager_session_save(s, msg: str, attachments, started_at: float | None) -> None:
    """Materialize the current user turn for eager first-turn persistence.

    The streaming thread still receives ``pending_user_message`` so existing
    cancel/recovery/final-merge paths keep their current contract. Eager mode
    only adds a durable display-message checkpoint before the agent launches.
    """
    if not msg:
        return
    existing = list(getattr(s, "messages", None) or [])
    if existing:
        latest = existing[-1]
        if isinstance(latest, dict) and latest.get("role") == "user":
            latest_text = " ".join(str(latest.get("content") or "").split())
            msg_text = " ".join(str(msg or "").split())
            if latest_text == msg_text:
                return
    user_msg = {"role": "user", "content": msg}
    if isinstance(started_at, (int, float)) and started_at > 0:
        user_msg["timestamp"] = int(started_at)
    if attachments:
        user_msg["attachments"] = list(attachments)
    s.messages.append(user_msg)


def _is_default_or_empty_session_title(title) -> bool:
    return str(title or "").strip() in ("", "Untitled", "New Chat")


def _provisional_title_from_prompt(prompt: str, fallback: str = "Untitled") -> str:
    text = str(prompt or "").strip()
    if not text:
        return fallback
    return title_from([{"role": "user", "content": text}], fallback) or fallback


def prepare_session_for_stream(
    s,
    *,
    msg: str,
    attachments,
    workspace: str,
    model: str,
    model_provider,
    stream_id: str,
    started_at: float | None = None,
    persist: bool = True,
):
    """Persist chat-start state according to webui.session_save_mode.

    ``deferred`` keeps the existing sidecar/WAL-backed behaviour: save pending
    fields but leave the display transcript empty until the agent merges the
    result. ``eager`` additionally writes the current user turn into messages so
    a process restart immediately after /api/chat/start preserves the prompt as
    a normal session message. Empty sessions are never saved here because this
    helper only runs after a non-empty message is validated.

    ``persist=False`` (plan 1.2) sets all the in-memory pending-state fields
    on ``s`` but skips the disk write — the caller starts the agent worker
    thread first and writes the session afterward with
    ``s.save(skip_index=True)`` so the SESSION_DIR glob in
    ``_write_session_index`` never sits on the chat/start request path.
    """
    s.workspace = workspace
    s.model = model
    s.model_provider = model_provider
    s.active_stream_id = stream_id
    s.pending_user_message = msg
    s.pending_attachments = attachments
    s.pending_started_at = started_at if started_at is not None else time.time()
    current_title = getattr(s, "title", None)
    if _is_default_or_empty_session_title(current_title):
        provisional_title = _provisional_title_from_prompt(msg, current_title or "Untitled")
        if provisional_title and not _is_default_or_empty_session_title(provisional_title):
            s.title = provisional_title
    if get_webui_session_save_mode() == "eager":
        _checkpoint_user_message_for_eager_session_save(
            s,
            msg,
            attachments,
            s.pending_started_at,
        )
    if persist:
        s.save()


def start_turn(
    s,
    *,
    msg: str,
    attachments=None,
    workspace: str,
    model: str,
    model_provider=None,
    normalized_model: bool = False,
    diag=None,
    goal_related: bool = False,
    turn: TurnOptions | None = None,
):
    """Persist pending state, register an SSE channel, and start an agent turn."""
    attachments = attachments or []
    # Prevent duplicate runs in the same session while a stream is still active.
    # This commonly happens after page refresh/reconnect races and can produce
    # duplicated clarify cards for what appears to be a single user request.
    diag.stage("active_stream_check") if diag else None
    current_stream_id = getattr(s, "active_stream_id", None)
    if current_stream_id:
        diag.stage("active_stream_lock_wait") if diag else None
        with STREAMS_LOCK:
            current_active = current_stream_id in STREAMS
        if current_active:
            diag.stage("response_write") if diag else None
            return {
                "error": "session already has an active stream",
                "active_stream_id": current_stream_id,
                "_status": 409,
            }
        # Stale stream id from a previous run; clear and continue.
        diag.stage("stale_stream_cleanup") if diag else None
        clear_stale_stream_state(s)

    # #1932: check if this session has a pending goal continuation flag.
    # The streaming hook sets PENDING_GOAL_CONTINUATION when goal_continue fires,
    # so the next chat/start for this session is automatically treated as goal-related.
    if not goal_related and s.session_id in PENDING_GOAL_CONTINUATION:
        goal_related = True
        PENDING_GOAL_CONTINUATION.discard(s.session_id)

    stream_id = uuid.uuid4().hex
    session_lock = _get_session_agent_lock(s.session_id)
    diag.stage("session_lock_wait") if diag else None
    with session_lock:
        diag.stage("save_pending_state") if diag else None
        # plan 1.2 — set the pending-state fields on `s` now (cheap, in-memory)
        # but defer the disk write (persist=False) until after the worker
        # thread has been started below, and skip the SESSION_DIR-globbing
        # index rewrite on that write entirely (skip_index=True) in favor of
        # a debounced background refresh.
        prepare_session_for_stream(
            s,
            msg=msg,
            attachments=attachments,
            workspace=workspace,
            model=model,
            model_provider=model_provider,
            stream_id=stream_id,
            persist=False,
        )
    diag.stage("turn_journal_submitted") if diag else None
    journal_event = {}
    try:
        from api.turn_journal import append_turn_journal_event
        journal_event = append_turn_journal_event(
            s.session_id,
            {
                "event": "submitted",
                "stream_id": stream_id,
                "role": "user",
                "content": msg,
                "attachments": attachments,
                "workspace": workspace,
                "model": model,
                "model_provider": model_provider,
                "created_at": s.pending_started_at,
            },
        )
    except Exception:
        logger.warning("Failed to append submitted turn journal event", exc_info=True)
    diag.stage("set_last_workspace") if diag else None
    set_last_workspace(workspace)
    diag.stage("stream_registration") if diag else None
    stream = create_stream_channel()
    with STREAMS_LOCK:
        STREAMS[stream_id] = stream
    # Tell every OTHER device with this chat open that a run just started, and
    # which stream to attach to. The run stream already broadcasts to every
    # subscriber; until now nobody else was ever told the stream_id, so the
    # fan-out had an audience of one.
    #
    # Published here -- after the stream is registered, before the worker starts
    # -- rather than at the end of this function. A run that fails instantly can
    # otherwise reach the worker's finally and publish run_ended FIRST, leaving
    # the other device holding a stream_id that is already gone and spinning on
    # it forever: exactly the case run_ended exists to prevent, inverted.
    try:
        SESSION_EVENTS.publish(s.session_id, "run_started", {
            "session_id": s.session_id,
            "stream_id": stream_id,
            "title": s.title,
        })
    except Exception:
        # An announcement is a nicety; never fail the turn the user asked for.
        logger.warning("Failed to announce run_started", exc_info=True)
    # #1932: mark stream as goal-related so the streaming hook evaluates the goal.
    if goal_related:
        STREAM_GOAL_RELATED[stream_id] = True
    diag.stage("worker_thread_start") if diag else None
    thr = threading.Thread(
        target=_run_agent_streaming,
        args=(s.session_id, msg, model, workspace, stream_id, attachments),
        kwargs={"model_provider": model_provider, "goal_related": goal_related,
                "turn": turn or TurnOptions()},
        daemon=True,
    )
    thr.start()
    # plan 1.2 — persist the pending state to disk only after the worker
    # thread has been kicked off, with skip_index=True so this write never
    # does the SESSION_DIR glob (see models._write_session_index). The
    # session index is refreshed shortly after via a debounced background
    # call so /api/sessions listings still pick up the new/updated session.
    diag.stage("save_pending_state_disk") if diag else None
    with session_lock:
        s.save(skip_index=True)
    try:
        from api.models import schedule_session_index_refresh
        schedule_session_index_refresh(s)
    except Exception:
        logger.warning("Failed to schedule session index refresh", exc_info=True)
    response = {
        "stream_id": stream_id,
        "session_id": s.session_id,
        "pending_started_at": s.pending_started_at,
        "turn_id": journal_event.get("turn_id"),
        "title": s.title,
    }
    if normalized_model:
        response["effective_model"] = model
    if model_provider:
        response["effective_model_provider"] = model_provider
    return response


def turn_options_for_chat(s, body, model, model_provider, context: str = "") -> TurnOptions:
    """Which agent harness a chat turn runs (api/harness_runner.py).

    * ``harness_id`` non-empty — the chat's own harness: run it, and the chat
      keeps it.
    * ``harness_id`` present but empty — a harness-aware client with no chat
      harness: follow the chat's stored one, else the Chat default. Nothing is
      saved, so a later default change still reaches this chat.
    * no ``harness_id`` key — an older client: its model runs as Single, exactly
      as before harnesses existed.

    An integration-setup session always runs Single on the model its picker
    sent (2026-11-04, his call): setup is a back-and-forth of questions and
    forms, and a harness hands it to a background job he cannot answer.
    """
    if getattr(s, "integration_setup", False) or "harness_id" not in body:
        return TurnOptions(explicit_model=(model, model_provider), context=context)
    hid = body.get("harness_id")
    hid = hid.strip() if isinstance(hid, str) else ""
    if hid:
        s.harness_id = hid
    return TurnOptions(harness_id=hid or None, context=context)


def start_chat_turn(session_id: str, message: str) -> dict:
    """Start a chat turn in an existing session from the server itself (the
    phone's Agents tab replying to a Jarvis chat). Same model, harness and
    workspace resolution as POST /api/chat/start. KeyError: no such session.
    Returns the start response ({stream_id, …} or {error, _status})."""
    s = get_session(session_id)
    workspace = _resolve_chat_workspace_with_recovery(s, None)
    model, model_provider, normalized_model = resolve_session_model_state(
        s.model, getattr(s, "model_provider", None))
    return start_turn(s, msg=message, workspace=workspace, model=model,
                      model_provider=model_provider, normalized_model=normalized_model,
                      turn=turn_options_for_chat(s, {}, model, model_provider))


def _resolve_chat_workspace_with_recovery(s, requested_workspace) -> str:
    """Recover stale implicit session workspaces without hiding explicit errors."""
    explicit = requested_workspace not in (None, "")
    candidate = requested_workspace if explicit else getattr(s, "workspace", None)
    try:
        return str(resolve_trusted_workspace(candidate))
    except ValueError:
        if explicit:
            raise
    fallback = str(resolve_trusted_workspace(get_last_workspace()))
    s.workspace = fallback
    try:
        s.save()
    except Exception:
        pass
    return fallback
