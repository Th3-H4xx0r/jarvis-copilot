"""Chat sessions over HTTP: /api/session* and /api/sessions* (mounted for both).

The session list with its CLI/messaging merge, one session's detail, and the
edits on one (rename, pin, archive, move, branch, truncate, delete, import ...).
Manual compression lives in api/session_compress.py, handoff summaries in
api/handoff_summary.py.
"""
import copy
import json
import logging
import os
import shutil
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qs

from api.agent_sessions import (
    MESSAGING_SOURCES,
    is_cli_session_row,
    is_cli_session_row_visible,
    read_session_lineage_report,
)
from api.chat_turns import clear_stale_stream_state
from api.config import (
    DEFAULT_MODEL,
    DEFAULT_WORKSPACE,
    LOCK,
    SESSIONS,
    SESSIONS_MAX,
    SESSION_AGENT_LOCKS,
    SESSION_AGENT_LOCKS_LOCK,
    SESSION_DIR,
    _get_session_agent_lock,
    load_settings,
)
from api.handoff_summary import _handle_conversation_rounds, _handle_handoff_summary
from api import helpers
from api.helpers import (
    _redact_text,
    _sanitize_error,
    bad,
    j,
    need,
    query_sid,
    redact_session_data,
    require,
)
from api.models import (
    SESSION_INDEX_FILE,
    Session,
    _active_state_db_path,
    all_sessions,
    ensure_cron_project,
    get_cli_session_messages,
    get_cli_sessions,
    get_session,
    import_cli_session,
    is_cron_session,
    load_projects,
    new_session,
    title_from,
)
from api.profiles import _profiles_match
from api.request_diagnostics import RequestDiagnostics
from api.run_journal import find_run_summary
from api.session_compress import _handle_session_compress, _handle_session_compress_start, _handle_session_compress_status
from api.session_model import (
    _split_provider_qualified_model,
    clean_session_provider,
    context_length_for,
    resolve_session_model_state,
)
from api.workspace import get_last_workspace, resolve_trusted_workspace, set_last_workspace

logger = logging.getLogger(__name__)

_MESSAGING_RAW_SOURCES = {str(s).strip().lower() for s in MESSAGING_SOURCES}
_MESSAGING_SESSION_METADATA_CACHE: dict[str, object] = {
    "path": None,
    "mtime": None,
    "identity": {},
}
_MESSAGING_SESSION_METADATA_LOCK = threading.Lock()
_STALE_MESSAGING_END_REASONS = {"session_reset", "session_switch"}


def _all_profiles_query_flag(parsed_url) -> bool:
    """Return True if the request URL has `?all_profiles=1` (or true/yes).

    Centralizes the opt-in parsing so /api/sessions and /api/projects use
    the same shape. Accepts 1/true/yes (case-insensitive) for ergonomics.
    """
    qs = parse_qs(parsed_url.query)
    raw = qs.get('all_profiles', [''])[0].strip().lower()
    return raw in ('1', 'true', 'yes', 'on')


def _worktree_retained_payload(session) -> dict:
    """Return explicit no-cleanup metadata for worktree-backed session actions."""
    worktree_path = getattr(session, "worktree_path", None) if session else None
    if not worktree_path:
        return {}
    payload = {
        "worktree_retained": True,
        "worktree_path": worktree_path,
    }
    worktree_branch = getattr(session, "worktree_branch", None)
    worktree_repo_root = getattr(session, "worktree_repo_root", None)
    if worktree_branch:
        payload["worktree_branch"] = worktree_branch
    if worktree_repo_root:
        payload["worktree_repo_root"] = worktree_repo_root
    return payload


def _worktree_retained_payload_for_session_id(sid: str) -> dict:
    try:
        return _worktree_retained_payload(get_session(sid, metadata_only=True))
    except KeyError:
        return {}
    except Exception:
        logger.debug("Failed to read worktree metadata for deleted session %s", sid)
        return {}


def _normalize_messaging_source(raw_source) -> str:
    return str(raw_source or "").strip().lower()


def _is_known_messaging_source(raw_source) -> bool:
    return _normalize_messaging_source(raw_source) in _MESSAGING_RAW_SOURCES


def _safe_first(*values):
    for value in values:
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ""


def _gateway_session_metadata_path():
    try:
        from api.profiles import get_active_hermes_home
        hermes_home = Path(get_active_hermes_home()).expanduser().resolve()
    except Exception:
        hermes_home = Path(os.getenv("HERMES_HOME", str(Path.home() / ".jarviscopilot"))).expanduser().resolve()
    return hermes_home / "sessions" / "sessions.json"


def _load_gateway_session_identity_map() -> dict[str, dict]:
    path = _gateway_session_metadata_path()
    if not path.exists():
        return {}

    try:
        st = path.stat()
        cache = _MESSAGING_SESSION_METADATA_CACHE
        with _MESSAGING_SESSION_METADATA_LOCK:
            if cache["path"] == str(path) and cache["mtime"] == st.st_mtime:
                return cache["identity"].copy()
    except Exception:
        return {}

    try:
        raw_sessions = json.loads(path.read_text(encoding="utf-8"))
    except Exception as _json_err:
        logger.debug("Failed to parse gateway sessions metadata from %s: %s", path, _json_err)
        return {}

    mapping: dict[str, dict] = {}
    if isinstance(raw_sessions, dict):
        for _entry in raw_sessions.values():
            if not isinstance(_entry, dict):
                continue
            session_id = _safe_first(_entry.get("session_id"))
            if not session_id:
                continue
            origin = _entry.get("origin") if isinstance(_entry.get("origin"), dict) else {}
            platform = _safe_first(origin.get("platform"), _entry.get("platform"))
            mapping[session_id] = {
                "session_key": _safe_first(_entry.get("session_key"), _entry.get("key")),
                "chat_id": _safe_first(origin.get("chat_id"), _entry.get("chat_id")),
                "thread_id": _safe_first(origin.get("thread_id"), _entry.get("thread_id")),
                "chat_type": _safe_first(origin.get("chat_type"), _entry.get("chat_type")),
                "user_id": _safe_first(origin.get("user_id"), _entry.get("user_id")),
                "platform": platform,
                "raw_source": platform,
            }

    with _MESSAGING_SESSION_METADATA_LOCK:
        _MESSAGING_SESSION_METADATA_CACHE["path"] = str(path)
        _MESSAGING_SESSION_METADATA_CACHE["mtime"] = st.st_mtime
        _MESSAGING_SESSION_METADATA_CACHE["identity"] = mapping
    return mapping.copy()


def _run_journal_status_payload(summary: dict, *, active: bool = False) -> dict:
    terminal = bool(summary.get("terminal"))
    terminal_state = summary.get("terminal_state")
    if not active and not terminal:
        terminal_state = "stale-from-restart"
    return {
        "session_id": summary.get("session_id"),
        "run_id": summary.get("run_id"),
        "last_seq": summary.get("last_seq"),
        "last_event_id": summary.get("last_event_id"),
        "last_event": summary.get("last_event"),
        "terminal": terminal,
        "terminal_state": terminal_state,
    }


def _ensure_full_session_before_mutation(sid: str, session):
    """Reload cached metadata-only sessions before mutating persisted fields.

    Session.save() intentionally refuses metadata-only stubs (#1558) because
    their messages list is empty by design. Mutation routes that save session
    metadata must upgrade the cached stub first so they do not trip that guard
    or risk writing an incomplete object.
    """
    if not getattr(session, "_loaded_metadata_only", False):
        return session
    full_session = Session.load(sid)
    if full_session is None:
        raise KeyError(sid)
    with LOCK:
        SESSIONS[sid] = full_session
        SESSIONS.move_to_end(sid)
        while len(SESSIONS) > SESSIONS_MAX:
            SESSIONS.popitem(last=False)
    return full_session


def session_or_404(sid, *, full: bool = False, metadata_only: bool = False):
    """The session ``sid``, or an HttpError 404. ``full`` upgrades a cached
    metadata-only stub first, as every route that saves the session must."""
    try:
        s = get_session(sid, metadata_only=True) if metadata_only else get_session(sid)
        return _ensure_full_session_before_mutation(sid, s) if full else s
    except KeyError:
        # helpers.HttpError looked up now, not at import: a test may reload api.helpers.
        raise helpers.HttpError("Session not found", 404) from None


def _reconcile_stale_stream_state_for_session_rows(session_rows) -> bool:
    """Clear stale persisted stream fields before /api/sessions serializes rows."""
    changed = False
    for row in session_rows:
        if not isinstance(row, dict):
            continue
        sid = row.get("session_id")
        if not sid or not row.get("active_stream_id"):
            continue
        if row.get("is_streaming") is True:
            continue
        try:
            session = get_session(sid, metadata_only=True)
        except Exception:
            logger.debug(
                "Failed to load session %s while reconciling stale stream state",
                sid,
                exc_info=True,
            )
            continue
        if session is None:
            continue
        changed = clear_stale_stream_state(session) or changed
    return changed


def _resolve_effective_session_model_for_display(session) -> str:
    """Resolve the model a session should display without mutating persisted state.

    `GET /api/session` should stay side-effect free. If a stale persisted model
    needs normalization for the current provider configuration, return the
    effective model for the response payload only and leave disk state alone.
    """
    original_model = getattr(session, "model", None) or ""
    effective_model, _provider, _changed = resolve_session_model_state(
        original_model or None,
        getattr(session, "model_provider", None),
    )
    return effective_model or original_model


def _resolve_effective_session_model_provider_for_display(session) -> str | None:
    original_model = getattr(session, "model", None) or ""
    _model, provider, _changed = resolve_session_model_state(
        original_model or None,
        getattr(session, "model_provider", None),
    )
    return provider


def _resolve_context_length_for_session_model(
    model: str | None,
    provider: str | None = None,
) -> int:
    """Best-effort current context window for a session model.

    Persisted session context metadata is a snapshot from a prior model call.
    During session hydration/model switching, the current model metadata should
    be allowed to replace that stale snapshot.
    """
    model_for_lookup = str(model or "").strip()
    if not model_for_lookup:
        return 0
    return context_length_for(model_for_lookup, provider=provider or "")


def _session_model_state_from_request(
    model: str | None,
    requested_provider: str | None,
    current_provider: str | None = None,
) -> tuple[str | None, str | None]:
    model_value = str(model).strip() if model is not None else None
    provider = (
        clean_session_provider(requested_provider)
        if requested_provider is not None
        else None
    )
    if model_value:
        _bare, explicit_provider = _split_provider_qualified_model(model_value)
        if explicit_provider:
            provider = explicit_provider
        elif requested_provider is None:
            provider = clean_session_provider(current_provider)
        model_value, provider, _changed = resolve_session_model_state(
            model_value,
            provider,
        )
    return model_value, provider


def _lookup_gateway_session_identity(session_id: str) -> dict:
    if not session_id:
        return {}
    metadata = _load_gateway_session_identity_map().get(str(session_id))
    return metadata if isinstance(metadata, dict) else {}


def _lookup_cli_session_metadata(session_id: str) -> dict:
    if not session_id:
        return {}
    try:
        for row in get_cli_sessions():
            if row.get("session_id") == session_id:
                return row
    except Exception:
        return {}
    return {}


def _messaging_session_identity(session: dict, raw_source: str) -> str:
    metadata = _lookup_gateway_session_identity(session.get("session_id"))
    session_key = _safe_first(
        metadata.get("session_key"),
        session.get("session_key"),
        session.get("gateway_session_key"),
    )
    if session_key:
        return f"{raw_source}|session_key:{session_key}"

    chat_id = _safe_first(
        metadata.get("chat_id"),
        session.get("chat_id"),
        session.get("origin_chat_id"),
    )
    thread_id = _safe_first(metadata.get("thread_id"), session.get("thread_id"))
    chat_type = _safe_first(metadata.get("chat_type"), session.get("chat_type"))
    user_id = _safe_first(
        metadata.get("user_id"),
        session.get("user_id"),
        session.get("origin_user_id"),
    )

    identity_parts = []
    if chat_type:
        identity_parts.append(f"chat_type:{chat_type}")
    if chat_id:
        identity_parts.append(f"chat_id:{chat_id}")
    if thread_id:
        identity_parts.append(f"thread_id:{thread_id}")
    if user_id:
        identity_parts.append(f"user_id:{user_id}")

    if identity_parts:
        return f"{raw_source}|" + "|".join(identity_parts)
    return raw_source


def _session_messaging_raw_source(session: dict) -> str:
    raw = _safe_first(
        session.get("raw_source"),
        session.get("source_tag"),
        session.get("source"),
        session.get("platform"),
    )
    if not raw:
        raw = session.get("source_label") or "messaging"
    return _normalize_messaging_source(raw)


def _has_durable_messaging_identity(session: dict) -> bool:
    metadata = _lookup_gateway_session_identity(session.get("session_id"))
    return bool(_safe_first(
        metadata.get("session_key"),
        session.get("session_key"),
        session.get("gateway_session_key"),
        metadata.get("chat_id"),
        session.get("chat_id"),
        session.get("origin_chat_id"),
        metadata.get("thread_id"),
        session.get("thread_id"),
    ))


def _numeric_count(value) -> int:
    try:
        return int(float(_safe_first(value, 0) or 0))
    except (TypeError, ValueError):
        return 0


def _should_hide_stale_messaging_session(
    session: dict,
    active_gateway_session_ids: set[str],
    active_gateway_sources: set[str],
) -> bool:
    """Hide stale Gateway-owned internal rows after an external chat moved on.

    JarvisCopilot Gateway keeps the external conversation identity in sessions.json.
    Compression/session-reset can leave old Agent state.db rows behind; those
    rows are implementation segments, not distinct conversations users chose.
    Only apply this aggressive hiding when Gateway is currently advertising an
    active session for the same messaging source. Without that source-of-truth
    file we keep the old fallback behavior.
    """
    raw_source = _session_messaging_raw_source(session)
    if not _is_known_messaging_source(raw_source):
        return False
    if not active_gateway_session_ids or raw_source not in active_gateway_sources:
        return False

    sid = _safe_first(session.get("session_id"))
    if sid and sid in active_gateway_session_ids:
        return False

    if _safe_first(session.get("end_reason")) in _STALE_MESSAGING_END_REASONS:
        return True

    if not _has_durable_messaging_identity(session):
        return True

    if session.get("parent_session_id"):
        return True

    message_count = _numeric_count(session.get("message_count"))
    actual_count = _numeric_count(session.get("actual_message_count"))
    if message_count <= 0 and actual_count <= 0:
        return True

    return False


def _is_messaging_session_record(session) -> bool:
    """Return true for sessions backed by external messaging channels."""
    if not session:
        return False
    if (
        (getattr(session, "session_source", None) if not isinstance(session, dict) else session.get("session_source")) == "messaging"
    ):
        return True
    raw = _safe_first(
        getattr(session, "raw_source", None) if not isinstance(session, dict) else session.get("raw_source"),
        getattr(session, "source_tag", None) if not isinstance(session, dict) else session.get("source_tag"),
        getattr(session, "source", None) if not isinstance(session, dict) else session.get("source"),
        session.get("source_label") if isinstance(session, dict) else None,
    )
    return _is_known_messaging_source(raw)


def _messages_include_tool_metadata(messages) -> bool:
    """Return true when returned messages can reconstruct their own tool cards."""
    if not isinstance(messages, list):
        return False
    for msg in messages:
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        if isinstance(msg.get("tool_calls"), list) and msg.get("tool_calls"):
            return True
        content = msg.get("content")
        if isinstance(content, list) and any(
            isinstance(part, dict) and part.get("type") == "tool_use"
            for part in content
        ):
            return True
    return False


def _session_requires_cli_metadata_lookup(session) -> bool:
    """Return True when a sidecar/session row still needs CLI metadata.

    Legacy imported sidecars may predate the ``read_only`` field and therefore
    load with ``read_only=False``. They still persist ``is_cli_session`` and/or
    source metadata from import time, so those markers intentionally keep them
    on the CLI lookup path while ordinary WebUI-native sessions take the fast
    path.

    Supersedes the simpler is-cli-or-messaging gate from PR #1822 — the new
    gate is strictly more inclusive (also covers ``read_only=True`` sidecars,
    ``session_source`` markers, and source_tag/raw_source/platform metadata)
    so all sessions that previously took the slow path still do, plus a few
    more legacy shapes.
    """
    if not session:
        return False

    def _field(name):
        return session.get(name) if isinstance(session, dict) else getattr(session, name, None)

    if _is_messaging_session_record(session):
        return True
    if bool(_field("is_cli_session")) or bool(_field("read_only")):
        return True
    session_source = _normalize_messaging_source(_safe_first(_field("session_source")))
    if session_source in {"messaging", "external_agent", "external-agent"}:
        return True
    return bool(_safe_first(
        _field("source_tag"),
        _field("raw_source"),
        _field("source"),
        _field("source_label"),
        _field("platform"),
    ))


def _is_messaging_session_id(sid: str) -> bool:
    """Detect messaging-backed sessions from WebUI metadata or Agent rows."""
    try:
        session = Session.load(sid)
        if _is_messaging_session_record(session):
            return True
    except Exception:
        pass
    return _is_messaging_session_record(_lookup_cli_session_metadata(sid))


def _session_sort_timestamp(session: dict) -> float:
    return float(
        _safe_first(
            session.get("last_message_at"),
            session.get("updated_at"),
            session.get("created_at"),
            session.get("started_at"),
            0,
        ) or 0
    ) or 0.0


def _is_cli_session_for_settings(session: dict) -> bool:
    """Return True for importable CLI sessions that are safe to classify for settings."""
    if not isinstance(session, dict):
        return False
    if is_cli_session_row(session):
        return True

    # Fallback for legacy local copies that had weak/empty metadata:
    # keep this conservative so messaging sessions do not collapse incorrectly.
    if not session.get("is_cli_session"):
        return False
    source = str(session.get("source") or "").strip().lower()
    if source in MESSAGING_SOURCES:
        return False
    title = str(session.get("title") or "").strip().lower()
    return title in ("", "untitled", "cli", "cli session") or title.endswith(" session") and (
        not source or source == "cli"
    )


CLI_VISIBLE_SESSION_CAP = 20


def _cap_recent_cli_sessions(sessions: list[dict], cli_cap: int = CLI_VISIBLE_SESSION_CAP) -> list[dict]:
    """Keep only the most recent CLI-visible sessions after filtering."""
    if cli_cap <= 0:
        return sessions
    kept = []
    cli_seen = 0
    for session in sessions:
        if _is_cli_session_for_settings(session):
            cli_seen += 1
            if cli_seen > cli_cap:
                continue
        kept.append(session)
    return kept


# Where a CLI/messaging session came from. The first four only label the
# source; the rest identify the messaging chat it belongs to.
CLI_SOURCE_FIELDS = ("source_tag", "raw_source", "session_source", "source_label")
CLI_META_FIELDS = CLI_SOURCE_FIELDS + (
    "user_id", "chat_id", "chat_type", "thread_id", "session_key", "platform",
)


def _apply_cli_meta(s, meta: dict) -> None:
    """Mark a WebUI Session as a CLI session and copy its CLI_META_FIELDS from
    ``meta`` (a get_cli_sessions() row). ``raw_source`` falls back to
    ``source_tag``."""
    s.is_cli_session = True
    for key in CLI_META_FIELDS:
        setattr(s, key, meta.get(key))
    s.raw_source = meta.get("raw_source") or meta.get("source_tag")


def _merge_cli_sidebar_metadata(ui_session: dict, cli_meta: dict) -> dict:
    """Merge source-of-truth CLI metadata into a sidebar session row.

    Preserve UI-owned state (archived/pinned) while replacing metadata that can
    legitimately drift in WebUI snapshots.
    """
    if not ui_session:
        return ui_session
    if not cli_meta:
        return dict(ui_session)
    merged = dict(ui_session)
    merged["is_cli_session"] = True
    for key in CLI_META_FIELDS + (
        "parent_session_id",
        "end_reason",
        "actual_message_count",
        "_lineage_root_id",
        "_lineage_tip_id",
        "_compression_segment_count",
    ):
        value = _safe_first(cli_meta.get(key))
        if value:
            merged[key] = value

    if cli_meta.get("created_at") is not None:
        merged["created_at"] = cli_meta["created_at"]
    if cli_meta.get("updated_at") is not None:
        merged["updated_at"] = cli_meta["updated_at"]
    if cli_meta.get("last_message_at") is not None:
        merged["last_message_at"] = cli_meta["last_message_at"]
    if cli_meta.get("message_count") is not None:
        merged["message_count"] = max(
            _numeric_count(merged.get("message_count")),
            _numeric_count(cli_meta.get("message_count")),
        )
    elif cli_meta.get("actual_message_count") is not None:
        merged["message_count"] = max(
            _numeric_count(merged.get("message_count")),
            _numeric_count(cli_meta.get("actual_message_count")),
        )

    if cli_meta.get("title"):
        current_title = merged.get("title")
        if not current_title or current_title == "Untitled":
            merged["title"] = cli_meta["title"]

    if cli_meta.get("model"):
        if not merged.get("model") or merged.get("model") == "unknown":
            merged["model"] = cli_meta["model"]
    return merged


def _messaging_source_key(session: dict) -> str | None:
    raw = _session_messaging_raw_source(session)
    if not _is_known_messaging_source(raw):
        return None
    return _messaging_session_identity(session, raw)


def _keep_latest_messaging_session_per_source(sessions: list[dict]) -> list[dict]:
    """Keep only the newest sidebar row per messaging session identity."""
    gateway_metadata = _load_gateway_session_identity_map()
    active_gateway_session_ids = {str(sid) for sid in gateway_metadata.keys() if sid}
    active_gateway_sources = {
        _normalize_messaging_source(_safe_first(meta.get("raw_source"), meta.get("platform")))
        for meta in gateway_metadata.values()
        if isinstance(meta, dict)
    }
    active_gateway_sources = {source for source in active_gateway_sources if _is_known_messaging_source(source)}

    kept_sources: set[str] = set()
    best_by_source: dict[str, dict] = {}
    kept: list[dict] = []
    for session in sessions:
        key = _messaging_source_key(session)
        if not key:
            kept.append(session)
            continue
        if _should_hide_stale_messaging_session(session, active_gateway_session_ids, active_gateway_sources):
            continue
        if key in kept_sources:
            kept_sources.add(key)
            current = best_by_source.get(key)
            if current is None or _session_sort_timestamp(session) > _session_sort_timestamp(current):
                best_by_source[key] = session
            continue
        kept_sources.add(key)
        best_by_source[key] = session

    kept.extend(best_by_source.values())
    kept.sort(key=_session_sort_timestamp, reverse=True)
    return kept


def delete_chat_session(sid: str) -> None:
    """Delete one chat session and everything hanging off it.

    Extracted from ``POST /api/session/delete`` so a second caller cannot get it
    half-right: the file, its .bak, the in-memory cache, the index, the cached
    agent, the attachment directory, the per-session lock, the workspace
    terminal and the CLI row all have to go together. The endpoint keeps its own
    policy checks (read-only imports, messaging sessions, worktrees); this is the
    mechanics.

    Raises ValueError for an id that is not a session id.
    """
    if not sid or not all(c in '0123456789abcdefghijklmnopqrstuvwxyz_'
                          for c in sid):
        raise ValueError("invalid session_id")
    # The chat's pictures (agent/chat_media.py) go too — unless a continuation
    # of this chat still shows them.
    try:
        from api import models as _models
        continued = any(str(row.get('parent_session_id') or '') == sid
                        for row in (_models.all_sessions() or []) if isinstance(row, dict))
        if not continued:
            from agent.chat_media import delete_media
            delete_media(sid)
    except Exception:
        logger.debug("Failed to clean chat media for deleted session %s", sid)
    with LOCK:
        SESSIONS.pop(sid, None)
    try:
        SESSION_INDEX_FILE.unlink(missing_ok=True)
    except Exception:
        logger.debug("Failed to unlink session index")
    from api.config import _evict_session_agent
    _evict_session_agent(sid)
    try:
        p = (SESSION_DIR / f"{sid}.json").resolve()
        p.relative_to(SESSION_DIR.resolve())
    except Exception as exc:
        raise ValueError("invalid session_id") from exc
    try:
        p.unlink(missing_ok=True)
        p.with_suffix('.json.bak').unlink(missing_ok=True)
    except Exception:
        logger.debug("Failed to unlink session file %s", p)
    try:
        from api.upload import _session_attachment_dir

        shutil.rmtree(_session_attachment_dir(sid), ignore_errors=True)
    except Exception:
        logger.debug("Failed to clean attachment dir for deleted session %s", sid)
    with SESSION_AGENT_LOCKS_LOCK:
        SESSION_AGENT_LOCKS.pop(sid, None)
    try:
        from api.terminal import close_terminal
        close_terminal(sid)
    except Exception:
        logger.debug("Failed to close workspace terminal for deleted session %s", sid)


def _handle_session_export(handler, parsed):
    sid = parse_qs(parsed.query).get("session_id", [""])[0]
    if not sid:
        return bad(handler, "session_id is required")
    try:
        s = get_session(sid)
    except KeyError:
        return bad(handler, "Session not found", 404)
    safe = redact_session_data(s.__dict__)
    payload = json.dumps(safe, ensure_ascii=False, indent=2)
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header(
        "Content-Disposition", f'attachment; filename="hermes-{sid}.json"'
    )
    handler.send_header("Content-Length", str(len(payload.encode("utf-8"))))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(payload.encode("utf-8"))
    return True


def _handle_sessions_search(handler, parsed):
    qs = parse_qs(parsed.query)
    q = qs.get("q", [""])[0].lower().strip()
    content_search = qs.get("content", ["1"])[0] == "1"
    depth = int(qs.get("depth", ["5"])[0])
    if not q:
        safe_sessions = []
        for s in all_sessions():
            item = dict(s)
            if isinstance(item.get("title"), str):
                item["title"] = _redact_text(item["title"])
            safe_sessions.append(item)
        return j(handler, {"sessions": safe_sessions})
    results = []
    for s in all_sessions():
        title_match = q in (s.get("title") or "").lower()
        if title_match:
            item = dict(s, match_type="title")
            if isinstance(item.get("title"), str):
                item["title"] = _redact_text(item["title"])
            results.append(item)
            continue
        if content_search:
            try:
                sess = get_session(s["session_id"])
                msgs = sess.messages[:depth] if depth else sess.messages
                for m in msgs:
                    c = m.get("content") or ""
                    if isinstance(c, list):
                        c = " ".join(
                            p.get("text", "")
                            for p in c
                            if isinstance(p, dict) and p.get("type") == "text"
                        )
                    if q in str(c).lower():
                        item = dict(s, match_type="content")
                        if isinstance(item.get("title"), str):
                            item["title"] = _redact_text(item["title"])
                        results.append(item)
                        break
            except (KeyError, Exception):
                pass
    return j(handler, {"sessions": results, "query": q, "count": len(results)})


def _handle_sessions_cleanup(handler, body, zero_only=False):
    cleaned = 0
    for p in SESSION_DIR.glob("*.json"):
        if p.name.startswith("_"):
            continue
        try:
            s = Session.load(p.stem)
            if zero_only:
                should_delete = s and len(s.messages) == 0
            else:
                should_delete = s and s.title == "Untitled" and len(s.messages) == 0
            if should_delete:
                with LOCK:
                    SESSIONS.pop(p.stem, None)
                p.unlink(missing_ok=True)
                cleaned += 1
        except Exception:
            logger.debug("Failed to clean up session file %s", p)
    if SESSION_INDEX_FILE.exists():
        SESSION_INDEX_FILE.unlink(missing_ok=True)
    return j(handler, {"ok": True, "cleaned": cleaned})


def _normalize_message_for_import_refresh(message: object) -> object:
    """Normalize message payloads for import refresh prefix checks.

    The strict dict comparison previously failed when existing messages held
    integer timestamps while refreshed messages held floating-point timestamps.
    Strip timing keys before comparison so we can safely treat semantic
    prefixes as equivalent.
    """
    if not isinstance(message, dict):
        return message
    normalized = dict(message)
    normalized.pop("timestamp", None)
    normalized.pop("_ts", None)
    return normalized


def _message_has_cli_tool_metadata(message: object) -> bool:
    if not isinstance(message, dict):
        return False
    if message.get("role") == "assistant" and message.get("tool_calls"):
        return True
    if message.get("role") == "tool" and (message.get("tool_call_id") or message.get("tool_name") or message.get("name")):
        return True
    return False


def _strip_cli_tool_metadata_for_refresh(message: object) -> object:
    if not isinstance(message, dict):
        return _normalize_message_for_import_refresh(message)
    normalized = _normalize_message_for_import_refresh(message)
    if not isinstance(normalized, dict):
        return normalized
    for key in ("tool_calls", "tool_call_id", "tool_name", "name"):
        normalized.pop(key, None)
    return normalized


def _is_cli_tool_metadata_enrichment(existing_messages: list, fresh_messages: list) -> bool:
    """Return True when fresh messages only add CLI tool metadata.

    Older imports from get_cli_session_messages() persisted assistant/tool rows
    without tool_calls, tool_call_id, or tool_name. After #1772 the refreshed
    transcript can have the same length but richer metadata, so re-imports must
    rebuild the stored sidecar even without a new row.
    """
    if not isinstance(existing_messages, list) or not isinstance(fresh_messages, list):
        return False
    if len(existing_messages) != len(fresh_messages):
        return False
    if any(_message_has_cli_tool_metadata(m) for m in existing_messages):
        return False
    if not any(_message_has_cli_tool_metadata(m) for m in fresh_messages):
        return False
    for idx, existing_message in enumerate(existing_messages):
        if _strip_cli_tool_metadata_for_refresh(existing_message) != _strip_cli_tool_metadata_for_refresh(fresh_messages[idx]):
            return False
    return True


def _is_messages_refresh_prefix_match(existing_messages: list, fresh_messages: list) -> bool:
    """Return True when existing_messages is a prefix of fresh_messages by value.

    This is a semantic comparison intended for import refresh, not deep
    structural equality. It intentionally ignores timing fields that may differ
    in type/precision between storage layers.
    """
    if not isinstance(existing_messages, list) or not isinstance(fresh_messages, list):
        return False
    if len(existing_messages) > len(fresh_messages):
        return False
    for idx, existing_message in enumerate(existing_messages):
        fresh_message = fresh_messages[idx]
        if _normalize_message_for_import_refresh(existing_message) != _normalize_message_for_import_refresh(fresh_message):
            return False
    return True


def _handle_session_import_cli(handler, body):
    """Import a single CLI session into the WebUI store."""
    try:
        require(body, "session_id")
    except ValueError as e:
        return bad(handler, str(e))

    sid = str(body["session_id"])

    # Check if already imported — refresh messages from CLI store if new ones arrived
    existing = Session.load(sid)
    if existing:
        fresh_msgs = get_cli_session_messages(sid)
        changed = False
        cli_meta = None
        for cs in list(get_cli_sessions()):
            if cs["session_id"] == sid:
                cli_meta = cs
                break
        if fresh_msgs and len(fresh_msgs) > len(existing.messages):
            # Prefix-equality guard: only extend if existing messages are a prefix of
            # the fresh CLI messages. Prevents silently dropping WebUI-added messages
            # on hybrid sessions (user sent messages via WebUI while CLI continued).
            if _is_messages_refresh_prefix_match(existing.messages, fresh_msgs):
                existing.messages = fresh_msgs
                changed = True
        elif fresh_msgs and _is_cli_tool_metadata_enrichment(existing.messages, fresh_msgs):
            # Same row count, richer payload: rebuild sidecars imported before
            # CLI tool metadata was preserved (#1772).
            existing.messages = fresh_msgs
            changed = True
        if cli_meta:
            updates = {
                "is_cli_session": True,
                "source_tag": existing.source_tag or cli_meta.get("source_tag"),
                "raw_source": existing.raw_source or cli_meta.get("raw_source") or cli_meta.get("source_tag"),
                "session_source": existing.session_source or cli_meta.get("session_source"),
                "source_label": existing.source_label or cli_meta.get("source_label"),
                "parent_session_id": existing.parent_session_id or cli_meta.get("parent_session_id"),
            }
            for attr, value in updates.items():
                if getattr(existing, attr, None) != value:
                    setattr(existing, attr, value)
                    changed = True
        if changed:
            existing.save(touch_updated_at=False)
        return j(
            handler,
            {
                "session": existing.compact()
                | {
                    "messages": existing.messages,
                    "is_cli_session": True,
                    "read_only": bool((cli_meta or {}).get("read_only")),
                },
                "imported": False,
            },
        )

    # Fetch messages from CLI store
    msgs = get_cli_session_messages(sid)
    if not msgs:
        return bad(handler, "Session not found in CLI store", 404)

    # Get profile, model, timestamps, and title from CLI session metadata
    cli_meta: dict = {}
    for cs in get_cli_sessions():
        if cs["session_id"] == sid:
            cli_meta = cs
            break
    profile = cli_meta.get("profile")
    model = cli_meta.get("model", "unknown")
    created_at = cli_meta.get("created_at")
    updated_at = cli_meta.get("updated_at")
    cli_title = cli_meta.get("title")
    cli_source_tag = cli_meta.get("source_tag")
    cli_parent_session_id = cli_meta.get("parent_session_id")
    cli_read_only = bool(cli_meta.get("read_only"))

    # Use the CLI session title if available (e.g., cron job name), otherwise derive from messages
    title = cli_title or title_from(msgs, "CLI Session")

    # Auto-assign cron sessions to the dedicated "Cron Jobs" project (#1079)
    cron_project_id = None
    if is_cron_session(sid, cli_source_tag):
        cron_project_id = ensure_cron_project()

    if cli_read_only:
        session_payload = {
            "session_id": sid,
            "title": title,
            "workspace": str(get_last_workspace()),
            "model": model,
            "message_count": len(msgs),
            "created_at": created_at,
            "updated_at": updated_at,
            "last_message_at": updated_at or created_at,
            "pinned": False,
            "archived": False,
            "project_id": None,
            "profile": profile,
            "is_cli_session": True,
            "source_tag": cli_source_tag,
            "raw_source": cli_meta.get("raw_source") or cli_source_tag,
            "session_source": cli_meta.get("session_source"),
            "source_label": cli_meta.get("source_label"),
            "parent_session_id": cli_parent_session_id,
            "read_only": True,
            "messages": msgs,
            "tool_calls": [],
        }
        return j(handler, {"session": session_payload, "imported": False})

    s = import_cli_session(
        sid,
        title,
        msgs,
        model,
        profile=profile,
        created_at=created_at,
        updated_at=updated_at,
        parent_session_id=cli_parent_session_id,
    )
    if cron_project_id:
        s.project_id = cron_project_id
    _apply_cli_meta(s, cli_meta)
    s._cli_origin = sid
    s.save(touch_updated_at=False)
    return j(
        handler,
        {
            "session": s.compact()
            | {
                "messages": msgs,
                "is_cli_session": True,
            },
            "imported": True,
        },
    )


def _handle_session_import(handler, body):
    """Import a session from a JSON export. Creates a new session with a new ID."""
    if not body or not isinstance(body, dict):
        return bad(handler, "Request body must be a JSON object")
    messages = body.get("messages")
    if not isinstance(messages, list):
        return bad(handler, 'JSON must contain a "messages" array')
    title = body.get("title", "Imported session")
    try:
        workspace = str(resolve_trusted_workspace(body.get("workspace", str(DEFAULT_WORKSPACE))))
    except (TypeError, ValueError) as e:
        return bad(handler, str(e))
    model = body.get("model", DEFAULT_MODEL)
    s = Session(
        title=title,
        workspace=workspace,
        model=model,
        messages=messages,
        tool_calls=body.get("tool_calls", []),
    )
    s.pinned = body.get("pinned", False)
    with LOCK:
        SESSIONS[s.session_id] = s
        SESSIONS.move_to_end(s.session_id)
        while len(SESSIONS) > SESSIONS_MAX:
            SESSIONS.popitem(last=False)
    s.save()
    return j(handler, {"ok": True, "session": s.compact() | {"messages": s.messages}})


# ── Route handlers ──────────────────────────────────────────────────────────

def _get_worktree_status(handler, parsed):
    query = parse_qs(parsed.query)
    sid = query.get("session_id", [""])[0]
    if not sid:
        return bad(handler, "session_id is required", status=400)
    s = session_or_404(sid, metadata_only=True)
    try:
        from api.worktrees import worktree_status_for_session

        return j(handler, {"status": worktree_status_for_session(s)})
    except ValueError as exc:
        return bad(handler, str(exc), status=400)
    except Exception as exc:
        logger.exception("failed to read worktree status for session %s", sid)
        return bad(handler, _sanitize_error(exc), status=500)


def _get_compress_status(handler, parsed):
    query = parse_qs(parsed.query)
    _handle_session_compress_status(handler, query.get("session_id", [""])[0])
    return True


def _get_detail(handler, parsed):
    import time as _time
    _t0 = _time.monotonic()
    _debug_slow = os.environ.get("HERMES_DEBUG_SLOW", "")
    query = parse_qs(parsed.query)
    sid = query.get("session_id", [""])[0]
    if not sid:
        return j(handler, {"error": "session_id is required"}, status=400)
    # ?messages=0 skips the message payload for fast session switching.
    # The frontend uses this when switching conversations in the sidebar
    # (only needs metadata). The full message array is loaded lazily
    # via ?messages=1 when the message panel opens.
    load_messages = query.get("messages", ["1"])[0] != "0"
    resolve_model_default = "1" if load_messages else "0"
    resolve_model = query.get("resolve_model", [resolve_model_default])[0] != "0"
    # ?msg_limit=N returns only the last N messages (tail window).
    # Used by the frontend for fast session switching — avoids serialising
    # and sending hundreds of messages when the user only sees the most
    # recent exchange.  Older messages are loaded on-demand via scrolling.
    _msg_limit = query.get("msg_limit", [None])[0]
    try:
        msg_limit = max(1, int(_msg_limit)) if _msg_limit else None
    except (ValueError, TypeError):
        msg_limit = None
    # ?msg_before=N — 0-based index into the full message array.
    # Returns messages before this index (for scroll-to-top lazy loading).
    # Combined with msg_limit for paging.
    _msg_before = query.get("msg_before", [None])[0]
    try:
        msg_before = int(_msg_before) if _msg_before else None
    except (ValueError, TypeError):
        msg_before = None
    try:
        _t1 = _time.monotonic()
        s = get_session(sid, metadata_only=(not load_messages))
        original_stream_id = getattr(s, "active_stream_id", None)
        clear_stale_stream_state(s)
        cli_meta = _lookup_cli_session_metadata(sid) if _session_requires_cli_metadata_lookup(s) else {}
        is_messaging_session = _is_messaging_session_record(s) or _is_messaging_session_record(cli_meta)
        cli_messages = []
        if is_messaging_session:
            cli_messages = get_cli_session_messages(sid)
        _t2 = _time.monotonic()
        effective_model = (
            _resolve_effective_session_model_for_display(s)
            if resolve_model
            else None
        )
        effective_provider = (
            _resolve_effective_session_model_provider_for_display(s)
            if resolve_model
            else None
        )
        _t3 = _time.monotonic()
        if load_messages:
            if is_messaging_session and cli_messages:
                sidecar_messages = getattr(s, "messages", []) or []
                # Recovery/aggregate sidecars can intentionally contain a
                # longer visible conversation than the single state.db
                # segment for this messaging session id. Prefer the longer
                # sidecar so repaired WebUI history is not hidden behind the
                # canonical per-segment transcript. When both sources carry
                # different slices of the same stitched conversation, merge
                # them chronologically and dedupe exact repeats.
                if sidecar_messages and sidecar_messages != cli_messages:
                    merged_messages = []
                    seen_message_keys = set()
                    for msg in sorted(list(cli_messages) + list(sidecar_messages), key=lambda m: (
                        float(m.get("timestamp") or 0),
                        str(m.get("role") or ""),
                        str(m.get("content") or ""),
                    )):
                        message_identity = msg.get("id") or msg.get("message_id")
                        if message_identity:
                            key = ("message_id", str(message_identity))
                        else:
                            key = (
                                "legacy",
                                str(msg.get("role") or ""),
                                str(msg.get("content") or ""),
                                str(msg.get("timestamp") or ""),
                                str(msg.get("tool_call_id") or ""),
                                str(msg.get("tool_name") or msg.get("name") or ""),
                            )
                        if key in seen_message_keys:
                            continue
                        seen_message_keys.add(key)
                        merged_messages.append(msg)
                    _all_msgs = merged_messages
                else:
                    _all_msgs = sidecar_messages if len(sidecar_messages) > len(cli_messages) else cli_messages
            else:
                _all_msgs = s.messages
        else:
            _all_msgs = []
        if load_messages:
            if msg_before is not None:
                # Scroll-to-top paging: msg_before is a 0-based index into
                # the full message list. Return the msg_limit messages that
                # appear *before* this index (i.e. older messages).
                # Using index instead of timestamp avoids issues with
                # duplicate/missing timestamps.
                _before_idx = max(0, min(int(msg_before), len(_all_msgs)))
                _slice = _all_msgs[:_before_idx]
                _truncated_msgs = _slice[-msg_limit:] if msg_limit else _slice
            elif msg_limit and len(_all_msgs) > msg_limit:
                _truncated_msgs = _all_msgs[-msg_limit:]
            else:
                _truncated_msgs = _all_msgs
        else:
            _truncated_msgs = _all_msgs
        # Resolve effective context_length with model-metadata fallback so
        # older sessions (pre-#1318) that have context_length=0 persisted
        # still render a meaningful indicator on load.  Mirrors the
        # SSE-path fallback in api/streaming.py:2333-2342.  Fixes #1436.
        #
        # #1896: pass config_context_length, provider, and custom_providers
        # so explicit config overrides win over the 256K default fallback.
        # Without these, an old session loaded after a user upgraded to a
        # 1M-context model with `model.context_length: 1048576` in
        # config.yaml gets a 256K window in the initial UI indicator and
        # /api/session/get response — the same wrong-window display this
        # fix addresses on the streaming side.
        _persisted_cl = getattr(s, "context_length", 0) or 0
        _threshold_tokens = getattr(s, "threshold_tokens", 0) or 0
        if (not _persisted_cl) or resolve_model:
            _model_for_lookup = (
                effective_model or getattr(s, "model", "") or ""
            ).strip()
            _fb_cl = _resolve_context_length_for_session_model(
                _model_for_lookup,
                effective_provider or getattr(s, "model_provider", None) or "",
            )
            if _fb_cl:
                if _persisted_cl and _fb_cl != _persisted_cl:
                    # The old threshold belongs to the old window. Hiding it
                    # is less misleading than rendering a stale compression
                    # threshold against a freshly resolved context length.
                    _threshold_tokens = 0
                _persisted_cl = _fb_cl
        _session_tool_calls = getattr(s, "tool_calls", []) if load_messages else []
        if (
            load_messages
            and msg_limit is not None
            and _messages_include_tool_metadata(_truncated_msgs)
        ):
            # The browser ignores session-level tool_calls when the returned
            # messages already carry per-message tool metadata. Avoid sending
            # the full historical list with a small tail window.
            _session_tool_calls = []
        raw = s.compact() | {
            "messages": _truncated_msgs,
            "tool_calls": _session_tool_calls,
            "active_stream_id": getattr(s, "active_stream_id", None),
            "pending_user_message": getattr(s, "pending_user_message", None),
            "pending_attachments": getattr(s, "pending_attachments", []) if load_messages else [],
            "pending_started_at": getattr(s, "pending_started_at", None),
            "context_length": _persisted_cl,
            "threshold_tokens": _threshold_tokens,
            "last_prompt_tokens": getattr(s, "last_prompt_tokens", 0) or 0,
        }
        if original_stream_id:
            try:
                journal = find_run_summary(original_stream_id)
            except Exception:
                journal = None
            if journal:
                raw["runtime_journal"] = _run_journal_status_payload(
                    journal,
                    active=bool(getattr(s, "active_stream_id", None)),
                )
        if cli_meta and _is_messaging_session_record(cli_meta):
            raw = _merge_cli_sidebar_metadata(raw, cli_meta)
        # Signal to the frontend that older messages were omitted.
        # For msg_before paging, compare against the filtered set,
        # not the full list — otherwise we signal truncation even when
        # all older messages were returned.
        if msg_before is not None:
            _truncated = load_messages and msg_limit is not None and len(_slice) > msg_limit
        else:
            _truncated = load_messages and msg_limit is not None and len(_all_msgs) > msg_limit
        raw["_messages_truncated"] = _truncated
        # Index of the first returned message in the full message array.
        # Frontend uses this as cursor for scroll-to-top paging.
        if msg_before is not None:
            raw["_messages_offset"] = max(0, _before_idx - len(_truncated_msgs))
        else:
            raw["_messages_offset"] = max(0, len(_all_msgs) - len(_truncated_msgs))
        _t4 = _time.monotonic()
        if effective_model:
            raw["model"] = effective_model
        if effective_provider:
            raw["model_provider"] = effective_provider
        redact = redact_session_data(raw)
        _t5 = _time.monotonic()
        resp = j(handler, {"session": redact})
        _t6 = _time.monotonic()
        if _debug_slow:
            logger.warning(
                "[SLOW] session_id=%s get_session=%.1fms model_resolve=%.1fms "
                "compact=%.1fms redact=%.1fms json_write=%.1fms total=%.1fms",
                sid,
                (_t2-_t1)*1000, (_t3-_t2)*1000, (_t4-_t3)*1000,
                (_t5-_t4)*1000, (_t6-_t5)*1000, (_t6-_t0)*1000,
            )
        return resp
    except KeyError:
        # Not a WebUI session -- try CLI store
        cli_meta = _lookup_cli_session_metadata(sid)
        msgs = get_cli_session_messages(sid)
        if msgs:
            sess = {
                "session_id": sid,
                "title": (cli_meta or {}).get("title", "CLI Session"),
                "workspace": (cli_meta or {}).get("workspace", ""),
                "model": (cli_meta or {}).get("model", "unknown"),
                "message_count": len(msgs),
                "created_at": (cli_meta or {}).get("created_at", 0),
                "updated_at": (cli_meta or {}).get("updated_at", 0),
                "last_message_at": (cli_meta or {}).get("last_message_at")
                or (cli_meta or {}).get("updated_at", 0)
                or (msgs[-1] if msgs else {"timestamp": 0}).get("timestamp", 0),
                "pinned": False,
                "archived": False,
                "project_id": None,
                "profile": (cli_meta or {}).get("profile"),
                "is_cli_session": True,
                "source_tag": (cli_meta or {}).get("source_tag"),
                "raw_source": (cli_meta or {}).get("raw_source"),
                "session_source": (cli_meta or {}).get("session_source"),
                "source_label": (cli_meta or {}).get("source_label"),
                "read_only": bool((cli_meta or {}).get("read_only")),
                "messages": msgs,
                "tool_calls": [],
            }
            sess = _merge_cli_sidebar_metadata(sess, cli_meta)
            return j(handler, {"session": redact_session_data(sess)})
        return bad(handler, "Session not found", 404)


def _get_lineage_report(handler, parsed):
    sid = query_sid(parsed, "session_id required")
    report = read_session_lineage_report(_active_state_db_path(), sid)
    if not report.get("found"):
        return bad(handler, "Session not found", 404)
    return j(handler, report)


def _get_recovery_audit(handler, parsed):
    from api.session_recovery import audit_session_recovery
    return j(handler, audit_session_recovery(SESSION_DIR, state_db_path=_active_state_db_path()))


def _get_status(handler, parsed):
    sid = query_sid(parsed, "Missing session_id")
    try:
        from api.session_ops import session_status
        clear_stale_stream_state(get_session(sid, metadata_only=True))
        return j(handler, session_status(sid))
    except KeyError:
        return bad(handler, "Session not found", 404)


def _get_yolo(handler, parsed):
    sid = query_sid(parsed, "Missing session_id")
    from api.approvals import is_session_yolo_enabled
    return j(handler, {"yolo_enabled": is_session_yolo_enabled(sid)})


def _get_usage(handler, parsed):
    sid = query_sid(parsed, "Missing session_id")
    try:
        from api.session_ops import session_usage
        return j(handler, session_usage(sid))
    except KeyError:
        return bad(handler, "Session not found", 404)


def _get_list(handler, parsed):
    diag = RequestDiagnostics.maybe_start("GET", parsed.path, logger=logger)
    try:
        diag.stage("all_sessions")
        webui_sessions = all_sessions(diag=diag)
        diag.stage("reconcile_stale_stream_state")
        if _reconcile_stale_stream_state_for_session_rows(webui_sessions):
            diag.stage("all_sessions_after_stale_stream_reconcile")
            webui_sessions = all_sessions(diag=diag)
        diag.stage("load_settings")
        settings = load_settings()
        show_cli_sessions = bool(settings.get("show_cli_sessions"))
        if show_cli_sessions:
            diag.stage("get_cli_sessions")
            cli = get_cli_sessions()
            diag.stage("merge_cli_sessions")
            cli_by_id = {s["session_id"]: s for s in cli}
            for s in webui_sessions:
                meta = cli_by_id.get(s.get("session_id"))
                if not meta:
                    continue
                if _is_messaging_session_record(meta):
                    s.update(_merge_cli_sidebar_metadata(s, meta))
                    if s.get("session_id") != meta.get("session_id"):
                        s["session_id"] = meta.get("session_id")
                else:
                    # Plain CLI rows only borrow the source labels, and only
                    # where the WebUI copy has none.
                    for key in CLI_SOURCE_FIELDS:
                        if not s.get(key) and meta.get(key):
                            s[key] = meta[key]
            # Apply the same CLI visibility semantics to imported local copies so
            # low-value imported artifacts do not leak into the sidebar.
            webui_sessions = [s for s in webui_sessions if is_cli_session_row_visible(s)]
            webui_ids = {s["session_id"] for s in webui_sessions}
            from api.models import _hide_from_default_sidebar as _cron_hide
            deduped_cli = [s for s in cli if s["session_id"] not in webui_ids and is_cli_session_row_visible(s) and not _cron_hide(s)]
        else:
            diag.stage("filter_webui_sessions")
            webui_sessions = [s for s in webui_sessions if not _is_cli_session_for_settings(s)]
            deduped_cli = []
        diag.stage("sort_sessions")
        merged = webui_sessions + deduped_cli
        merged.sort(
            key=lambda s: s.get("last_message_at") or s.get("updated_at", 0) or 0,
            reverse=True,
        )
        # ── Profile scoping (#1611) ────────────────────────────────────────
        # Default: filter to the active profile. ?all_profiles=1 opts into
        # the aggregate view used by the "All profiles" sidebar toggle.
        # The other_profile_count is always returned so the UI can render
        # the "Show N from other profiles" affordance without sending the
        # cross-profile rows by default.
        #
        # IMPORTANT: scope BEFORE _keep_latest_messaging_session_per_source.
        # _messaging_source_key is profile-blind (#1614 follow-up): if the
        # same Slack/Telegram identity has sessions in profiles A and B, a
        # profile-blind dedupe would discard the older one even when scoped
        # to its own profile, leaving that profile with zero rows for that
        # source. Filter first so the dedupe operates only within the active
        # profile's rows.
        diag.stage("active_profile")
        from api.profiles import get_active_profile_name
        active_profile = get_active_profile_name()
        all_profiles = _all_profiles_query_flag(parsed)
        diag.stage("profile_filter")
        if all_profiles:
            scoped = merged
            other_profile_count = 0
        else:
            scoped = [s for s in merged
                      if _profiles_match(s.get("profile"), active_profile)]
            other_profile_count = len(merged) - len(scoped)
        diag.stage("messaging_dedupe")
        scoped = _keep_latest_messaging_session_per_source(scoped)
        if show_cli_sessions:
            diag.stage("cli_cap")
            scoped = _cap_recent_cli_sessions(scoped, cli_cap=CLI_VISIBLE_SESSION_CAP)
        # ?limit=N: only the N most recent. The phone's chat widget wants the latest
        # chat, and the whole list is ~1.1 KB a chat (660 KB at 578, 2026-10-17).
        limit_raw = parse_qs(parsed.query).get("limit", [""])[0]
        if limit_raw.isdigit() and int(limit_raw) > 0:
            scoped = scoped[: int(limit_raw)]
        diag.stage("redact_sessions")
        safe_merged = []
        for s in scoped:
            item = dict(s)
            if isinstance(item.get("title"), str):
                item["title"] = _redact_text(item["title"])
            safe_merged.append(item)
        diag.stage("response_write")
        return j(handler, {
            "sessions": safe_merged,
            "cli_count": len(deduped_cli),
            "all_profiles": all_profiles,
            "active_profile": active_profile,
            "other_profile_count": other_profile_count,
            "server_time": time.time(),
            "server_tz": time.strftime("%z"),
        })
    finally:
        diag.finish()


def _post_recovery_repair_safe(handler, parsed, body):
    from api.session_recovery import repair_safe_session_recovery
    result = repair_safe_session_recovery(SESSION_DIR, state_db_path=_active_state_db_path())
    return j(handler, result, status=200 if result.get("clean") else 409)


def _post_new(handler, parsed, body):
    try:
        workspace = str(resolve_trusted_workspace(body.get("workspace"))) if body.get("workspace") else None
    except (TypeError, ValueError) as e:
        return bad(handler, str(e))
    worktree_info = None
    worktree_requested = (
        body.get("worktree") is True
        or str(body.get("worktree")).strip().lower() in {"1", "true", "yes", "on"}
    )
    if worktree_requested:
        try:
            from api.worktrees import create_worktree_for_workspace
            base_workspace = workspace
            if not base_workspace:
                base_workspace = str(resolve_trusted_workspace(get_last_workspace()))
            worktree_info = create_worktree_for_workspace(base_workspace)
            workspace = worktree_info["path"]
        except (TypeError, ValueError) as e:
            return bad(handler, str(e), status=400)
        except Exception as e:
            logger.exception("failed to create worktree-backed session")
            return bad(handler, f"Failed to create worktree: {e}", status=500)
    model, model_provider = _session_model_state_from_request(
        body.get("model"),
        body.get("model_provider"),
    )
    # Use the profile sent by the client tab (if any) so that two tabs on
    # different profiles never clobber each other via the process-level global.
    s = new_session(
        workspace=workspace,
        model=model,
        model_provider=model_provider,
        profile=body.get("profile") or None,
        project_id=body.get("project_id") or None,
        worktree_info=worktree_info,
    )
    return j(handler, {"session": s.compact() | {"messages": s.messages}})


def _post_duplicate(handler, parsed, body):
    try:
        sid = body.get("session_id")
        if not sid:
            return bad(handler, "session_id is required")

        session = Session.load(sid)
        if not session:
            # 404, not 400 — missing resource, not a malformed request.
            return bad(handler, "Session not found", status=404)

        # Deep-copy mutable lists so the duplicate is *actually* independent.
        # `Session.__init__` does `self.messages = messages or []` — plain
        # assignment, no copy. Without deepcopy, both sessions share the same
        # list object in memory; appending to one mutates the other.
        # Items inside `messages` are dicts with mutable values (tool_calls,
        # content arrays), so a shallow `list(...)` is not enough.
        copied_session = Session(
            session_id=uuid.uuid4().hex[:12],
            # Defensive: legacy sessions may have title=None on disk; fall back to 'Untitled'
            # so `+ " (copy)"` doesn't TypeError.
            title=(session.title or "Untitled") + " (copy)",
            workspace=session.workspace,
            model=session.model,
            model_provider=session.model_provider,
            messages=copy.deepcopy(session.messages),
            tool_calls=copy.deepcopy(session.tool_calls),
            # Reset ephemeral / per-session-instance flags. Duplicating an
            # archived conversation should produce a visible (un-archived)
            # copy; pinned status doesn't transfer either.
            pinned=False,
            archived=False,
            project_id=session.project_id,
            profile=session.profile,
            input_tokens=session.input_tokens,
            output_tokens=session.output_tokens,
            estimated_cost=session.estimated_cost,
            # Per-session settings the user may have customized — carry them over
            # so the duplicate behaves identically until further edits. Compression
            # anchor + last_prompt_tokens are intentionally NOT carried — those
            # re-derive on the next turn.
            personality=session.personality,
            enabled_toolsets=getattr(session, "enabled_toolsets", None),
            context_length=getattr(session, "context_length", None),
            threshold_tokens=getattr(session, "threshold_tokens", None),
            created_at=time.time(),
            updated_at=time.time(),
        )

        with LOCK:
            SESSIONS[copied_session.session_id] = copied_session
            SESSIONS.move_to_end(copied_session.session_id)
            while len(SESSIONS) > SESSIONS_MAX:
                SESSIONS.popitem(last=False)
        # Persist immediately. The pre-PR flow (/api/session/new + /api/session/rename)
        # accidentally avoided this because `/api/session/rename` calls `s.save()`.
        # Without this explicit save, the duplicate is in-memory only — if the user
        # refreshes before sending a turn, the duplicate vanishes.
        copied_session.save()

        return j(handler, {"session": copied_session.compact() | {"messages": copied_session.messages}})
    except Exception as e:
        return bad(handler, str(e))


def _post_sessions_cleanup(handler, parsed, body):
    return _handle_sessions_cleanup(handler, body, zero_only=False)


def _post_sessions_cleanup_zero_message(handler, parsed, body):
    return _handle_sessions_cleanup(handler, body, zero_only=True)


def _post_rename(handler, parsed, body):
    need(body, "session_id", "title")
    s = session_or_404(body["session_id"], full=True)
    with _get_session_agent_lock(body["session_id"]):
        s.title = str(body["title"]).strip()[:80] or "Untitled"
        s.save()
    return j(handler, {"session": s.compact()})


def _post_append(handler, parsed, body):
    # Persist an on-device turn (handled locally on the phone, no server
    # agent) into the session transcript so it shows on the web + other
    # devices. Appends a user message and/or an assistant message verbatim.
    need(body, "session_id")
    sid = body["session_id"]
    s = session_or_404(sid, full=True)
    user_text = str(body.get("user") or "").strip()
    assistant_text = str(body.get("assistant") or "").strip()
    on_device = body.get("on_device") is True
    appended = 0
    with _get_session_agent_lock(sid):
        if user_text:
            s.messages.append({"role": "user", "content": user_text})
            appended += 1
        if assistant_text:
            a_msg = {"role": "assistant", "content": assistant_text}
            if on_device:
                a_msg["on_device"] = True
            s.messages.append(a_msg)
            appended += 1
        if appended:
            s.save()
    return j(handler, {"ok": True, "appended": appended})


def _post_harness(handler, parsed, body):
    """Set or clear a chat's harness. POST {session_id, harness_id | null}."""
    need(body, "session_id")
    _hid = body.get("harness_id")
    if _hid is not None:
        from api.harness_store import store_for_request as harness_store
        if not isinstance(_hid, str) or harness_store().get(_hid) is None:
            return bad(handler, "unknown harness")
    s = session_or_404(body["session_id"])
    with _get_session_agent_lock(body["session_id"]):
        s.harness_id = _hid or None
        s.save()
    return j(handler, {"ok": True, "harness_id": s.harness_id})


def _post_toolsets(handler, parsed, body):
    """Set or clear per-session toolset override (#493).

    POST body: { session_id, toolsets: [...] | null }
    - toolsets: list of toolset names to restrict the session to, or null to clear.
    """
    need(body, "session_id")
    sid = body["session_id"]
    toolsets = body.get("toolsets")
    # Validate: if not None, must be a non-empty list of strings
    if toolsets is not None:
        if not isinstance(toolsets, list) or not toolsets:
            return bad(handler, "toolsets must be a non-empty list or null")
        if not all(isinstance(t, str) and t for t in toolsets):
            return bad(handler, "each toolset must be a non-empty string")
    s = session_or_404(sid)
    with _get_session_agent_lock(sid):
        s.enabled_toolsets = toolsets
        s.save()
    return j(handler, {"ok": True, "enabled_toolsets": s.enabled_toolsets})


def _post_draft(handler, parsed, body):
    # GET ?session_id=X  → return current draft
    # POST body          → save draft { session_id, text?, files? }
    # HTTP method is in handler.command (e.g. "POST", "GET"), parsed has no .method
    if handler.command == "GET":
        query = parse_qs(parsed.query)
        sid = query.get("session_id", [""])[0] if parsed.query else ""
        if not sid:
            return bad(handler, "session_id is required", 400)
        s = session_or_404(sid)
        draft = getattr(s, "composer_draft", {}) or {}
        return j(handler, {"draft": draft})
    # POST
    need(body, "session_id")
    sid = body["session_id"]
    text = body.get("text")
    files = body.get("files")
    # Stage-326 hardening (per Opus advisor): size + type validation on
    # the draft inputs. Without this, a misbehaving or malicious client
    # can persist multi-MB strings into the session JSON on every keystroke
    # via the 400ms debounced auto-save.
    _MAX_DRAFT_TEXT = 50_000  # 50 KB cap on textarea content
    _MAX_DRAFT_FILES = 50  # max number of attached file references
    if text is not None and not isinstance(text, str):
        text = ""
    if isinstance(text, str) and len(text) > _MAX_DRAFT_TEXT:
        text = text[:_MAX_DRAFT_TEXT]
    if files is not None and not isinstance(files, list):
        files = []
    if isinstance(files, list) and len(files) > _MAX_DRAFT_FILES:
        files = files[:_MAX_DRAFT_FILES]
    s = session_or_404(sid)
    with _get_session_agent_lock(sid):
        draft = getattr(s, "composer_draft", {}) or {}
        if text is not None:
            draft["text"] = text
        if files is not None:
            draft["files"] = files
        s.composer_draft = draft
        # A keystroke is not "the chat moved": this fires every 400ms while
        # typing, and each announcement costs every other device a sidebar
        # refresh for a draft it cannot even see.
        s.save(announce=False)
    return j(handler, {"ok": True, "draft": s.composer_draft})


def _post_update(handler, parsed, body):
    need(body, "session_id")
    s = session_or_404(body["session_id"])
    old_ws = getattr(s, "workspace", "")
    old_model = getattr(s, "model", None)
    old_provider = getattr(s, "model_provider", None)
    try:
        new_ws = str(resolve_trusted_workspace(body.get("workspace", s.workspace)))
    except ValueError as e:
        return bad(handler, str(e))
    with _get_session_agent_lock(body["session_id"]):
        s.workspace = new_ws
        if "model" in body or "model_provider" in body:
            model, provider = _session_model_state_from_request(
                body.get("model", s.model),
                body.get("model_provider") if "model_provider" in body else None,
                getattr(s, "model_provider", None),
            )
            if model is not None:
                s.model = model
            s.model_provider = provider
            if (
                str(old_model or "") != str(getattr(s, "model", "") or "")
                or str(old_provider or "") != str(getattr(s, "model_provider", "") or "")
            ):
                s.context_length = _resolve_context_length_for_session_model(
                    getattr(s, "model", None),
                    getattr(s, "model_provider", None),
                )
                s.threshold_tokens = 0
                s.last_prompt_tokens = 0
        s.save()
    if str(old_ws or "") != str(new_ws or ""):
        try:
            from api.terminal import close_terminal
            close_terminal(body["session_id"])
        except Exception:
            logger.debug("Failed to close workspace terminal after workspace update")
    set_last_workspace(new_ws)
    return j(handler, {"session": s.compact() | {"messages": s.messages}})


def _post_worktree_remove(handler, parsed, body):
    sid = body.get("session_id", "")
    if not sid or not isinstance(sid, str) or not sid.strip():
        return bad(handler, "session_id must be a non-empty string", status=400)
    sid = sid.strip()
    if not all(c in '0123456789abcdefghijklmnopqrstuvwxyz_' for c in sid):
        return bad(handler, "Invalid session_id", 400)
    s = session_or_404(sid, metadata_only=True)
    force = bool(body.get("force", False))
    try:
        from api.worktrees import remove_worktree_for_session

        result = remove_worktree_for_session(s, force=force)
        return j(handler, result)
    except ValueError as exc:
        return bad(handler, str(exc), status=400)
    except Exception as exc:
        logger.exception("failed to remove worktree for session %s", sid)
        return bad(handler, _sanitize_error(exc), status=500)


def _post_delete(handler, parsed, body):
    sid = body.get("session_id", "")
    if not sid:
        return bad(handler, "session_id is required")
    if not all(c in '0123456789abcdefghijklmnopqrstuvwxyz_' for c in sid):
        return bad(handler, "Invalid session_id", 400)
    cli_meta_for_delete = _lookup_cli_session_metadata(sid)
    if cli_meta_for_delete.get("read_only"):
        return bad(handler, "Read-only imported sessions cannot be deleted from WebUI", 400)
    is_messaging_session = _is_messaging_session_id(sid)
    worktree_retained = _worktree_retained_payload_for_session_id(sid)
    # Delete from WebUI session store (shared with the live-session delete,
    # which has to remove the chat it paired).
    try:
        delete_chat_session(sid)
    except ValueError:
        return bad(handler, "Invalid session_id", 400)
    # Also delete from CLI state.db for CLI sessions shown in sidebar,
    # but never erase external messaging channel memory via WebUI delete.
    if not is_messaging_session:
        try:
            from api.models import delete_cli_session

            delete_cli_session(sid)
        except Exception:
            logger.debug("Failed to delete CLI session %s", sid)
    return j(handler, {"ok": True, **worktree_retained})


def _post_clear(handler, parsed, body):
    need(body, "session_id")
    s = session_or_404(body["session_id"])
    with _get_session_agent_lock(body["session_id"]):
        s.messages = []
        s.tool_calls = []
        s.title = "Untitled"
        s.save()
        # Evict cached agent — cleared session is a fresh conversation
        from api.config import _evict_session_agent
        _evict_session_agent(body["session_id"])
    return j(handler, {"ok": True, "session": s.compact()})


def _post_truncate(handler, parsed, body):
    need(body, "session_id")
    if body.get("keep_count") is None:
        return bad(handler, "Missing required field(s): keep_count")
    s = session_or_404(body["session_id"])
    keep = int(body["keep_count"])
    with _get_session_agent_lock(body["session_id"]):
        s.messages = s.messages[:keep]
        s.save()
    return j(
        handler, {"ok": True, "session": s.compact() | {"messages": s.messages}}
    )


def _post_branch(handler, parsed, body):
    # Fork a conversation from any message point (#465).
    # Accepts: {session_id, keep_count?, title?}
    #   keep_count: number of messages to copy (0=empty, undefined=full history)
    #   title: custom title (defaults to "<original title> (fork)")
    need(body, "session_id")
    # Reject non-string session_id explicitly so the failure surfaces as a
    # 400 instead of a generic 500 from get_session() raising TypeError.
    # (Opus pre-release follow-up.)
    if not isinstance(body["session_id"], str):
        return bad(handler, "session_id must be a string")
    source = session_or_404(body["session_id"])

    keep_count = body.get("keep_count")
    if keep_count is not None:
        try:
            keep_count = int(keep_count)
        except (ValueError, TypeError):
            return bad(handler, "keep_count must be an integer")
        # Negative slice (`messages[:-N]`) returns "all but last N", which
        # is a confusing fork semantic. Reject explicitly so the user
        # doesn't accidentally fork a session with the tail truncated when
        # they meant to copy the prefix. (Opus pre-release follow-up.)
        if keep_count < 0:
            return bad(handler, "keep_count must be non-negative")

    custom_title = body.get("title")
    if custom_title:
        custom_title = str(custom_title).strip()[:80] or None

    # Build messages slice
    source_messages = source.messages or []
    if keep_count is not None:
        forked_messages = source_messages[:keep_count]
    else:
        forked_messages = list(source_messages)

    # Derive title
    if custom_title:
        branch_title = custom_title
    else:
        source_title = source.title or "Untitled"
        branch_title = f"{source_title} (fork)"

    # Create new session inheriting workspace/model/profile
    branch = Session(
        workspace=source.workspace,
        model=source.model,
        profile=getattr(source, "profile", None),
        title=branch_title,
        messages=forked_messages,
        parent_session_id=source.session_id,
        session_source="fork",
    )
    with LOCK:
        SESSIONS[branch.session_id] = branch
        SESSIONS.move_to_end(branch.session_id)
        while len(SESSIONS) > SESSIONS_MAX:
            SESSIONS.popitem(last=False)

    # Persist only if there are messages (matches new_session pattern)
    if forked_messages:
        branch.save()

    return j(handler, {
        "session_id": branch.session_id,
        "title": branch_title,
        "parent_session_id": source.session_id,
    })


def _rewind(handler, body, op_name: str):
    """retry / undo: drop the last user turn (and what followed) via session_ops."""
    need(body, "session_id")
    from api import session_ops
    try:
        result = getattr(session_ops, op_name)(body["session_id"])
    except KeyError:
        return bad(handler, "Session not found", 404)
    except ValueError as e:
        return j(handler, {"error": str(e)})
    return j(handler, {"ok": True, **result})


# Session-scoped only — stored in-memory on the server side.
# Important lifecycle notes:
#   • Page reload: state PERSISTS (frontend re-fetches via GET endpoint)
#   • Cross-tab: state is SHARED (same server-side flag per session)
#   • Server restart: state is LOST (in-memory only)
#   • Cross-session: isolated (each session has its own flag)
# Fixes #467
def _post_yolo(handler, parsed, body):
    need(body, "session_id")
    sid = body["session_id"]
    enabled = bool(body.get("enabled", True))
    from api.approvals import set_yolo
    set_yolo(sid, enabled)
    return j(handler, {"ok": True, "yolo_enabled": enabled})


def _post_pin(handler, parsed, body):
    need(body, "session_id")
    s = session_or_404(body["session_id"], full=True)
    with _get_session_agent_lock(body["session_id"]):
        s.pinned = bool(body.get("pinned", True))
        s.save()
    return j(handler, {"ok": True, "session": s.compact()})


def _post_archive(handler, parsed, body):
    need(body, "session_id")
    sid = body["session_id"]
    try:
        s = _ensure_full_session_before_mutation(sid, get_session(sid))
    except KeyError:
        cli_meta = _lookup_cli_session_metadata(sid)
        if not cli_meta:
            return bad(handler, "Session not found", 404)
        if cli_meta.get("read_only"):
            return bad(handler, "Read-only imported sessions cannot be archived from WebUI", 400)
        if _is_messaging_session_record(cli_meta):
            s = Session(
                session_id=sid,
                title=cli_meta.get("title") or title_from(get_cli_session_messages(sid), "CLI Session"),
                workspace=get_last_workspace(),
                messages=[],
                model=cli_meta.get("model") or "unknown",
                created_at=cli_meta.get("created_at"),
                updated_at=cli_meta.get("updated_at"),
            )
            _apply_cli_meta(s, cli_meta)
            s.save(touch_updated_at=False)
        else:
            msgs = get_cli_session_messages(sid)
            if not msgs:
                return bad(handler, "Session not found", 404)
            s = import_cli_session(
                sid,
                cli_meta.get("title") or title_from(msgs, "CLI Session"),
                msgs,
                cli_meta.get("model") or "unknown",
                profile=cli_meta.get("profile"),
                created_at=cli_meta.get("created_at"),
                updated_at=cli_meta.get("updated_at"),
            )
            _apply_cli_meta(s, cli_meta)
    with _get_session_agent_lock(sid):
        s.archived = bool(body.get("archived", True))
        s.save(touch_updated_at=False)
    return j(handler, {"ok": True, "session": s.compact(), **_worktree_retained_payload(s)})


def _post_move(handler, parsed, body):
    need(body, "session_id")
    s = session_or_404(body["session_id"])
    # #1614: refuse moves into a project owned by another profile.
    target_pid = body.get("project_id") or None
    if target_pid:
        from api.profiles import get_active_profile_name
        active_profile = get_active_profile_name()
        target = next(
            (p for p in load_projects() if p["project_id"] == target_pid),
            None,
        )
        if not target:
            return bad(handler, "Project not found", 404)
        if not _profiles_match(target.get("profile"), active_profile):
            return bad(handler, "Project not found", 404)
    with _get_session_agent_lock(body["session_id"]):
        s.project_id = target_pid
        s.save()
    return j(handler, {"ok": True, "session": s.compact()})


_GET = {
    "/api/session/worktree/status": _get_worktree_status,
    "/api/session/compress/status": _get_compress_status,
    "/api/session": _get_detail,
    "/api/session/lineage/report": _get_lineage_report,
    "/api/session/recovery/audit": _get_recovery_audit,
    "/api/session/status": _get_status,
    "/api/session/yolo": _get_yolo,
    "/api/session/usage": _get_usage,
    "/api/sessions": _get_list,
    "/api/session/export": _handle_session_export,
    "/api/sessions/search": _handle_sessions_search,
}

_POST = {
    "/api/session/recovery/repair-safe": _post_recovery_repair_safe,
    "/api/session/new": _post_new,
    "/api/session/duplicate": _post_duplicate,
    "/api/sessions/cleanup": _post_sessions_cleanup,
    "/api/sessions/cleanup_zero_message": _post_sessions_cleanup_zero_message,
    "/api/session/rename": _post_rename,
    "/api/session/append": _post_append,
    "/api/session/harness": _post_harness,
    "/api/session/toolsets": _post_toolsets,
    "/api/session/draft": _post_draft,
    "/api/session/update": _post_update,
    "/api/session/worktree/remove": _post_worktree_remove,
    "/api/session/delete": _post_delete,
    "/api/session/clear": _post_clear,
    "/api/session/truncate": _post_truncate,
    "/api/session/branch": _post_branch,
    "/api/session/compress/start": lambda h, p, b: _handle_session_compress_start(h, b),
    "/api/session/compress": lambda h, p, b: _handle_session_compress(h, b),
    "/api/session/conversation-rounds": lambda h, p, b: _handle_conversation_rounds(h, b),
    "/api/session/handoff-summary": lambda h, p, b: _handle_handoff_summary(h, b),
    "/api/session/retry": lambda h, p, b: _rewind(h, b, "retry_last"),
    "/api/session/undo": lambda h, p, b: _rewind(h, b, "undo_last"),
    "/api/session/yolo": _post_yolo,
    "/api/session/pin": _post_pin,
    "/api/session/archive": _post_archive,
    "/api/session/move": _post_move,
    "/api/session/import": lambda h, p, b: _handle_session_import(h, b),
    "/api/session/import_cli": lambda h, p, b: _handle_session_import_cli(h, b),
}


def route(req):
    if req.method == "GET":
        fn = _GET.get(req.path)
        return False if fn is None else fn(req.handler, req.parsed)
    fn = _POST.get(req.path) if req.method == "POST" else None
    return False if fn is None else fn(req.handler, req.parsed, req.body)

