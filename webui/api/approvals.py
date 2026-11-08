"""Approval prompts for the WebUI: the per-session queue the UI shows, its SSE
push, and the answers (a chat card, a Background job's card, the Agents tab and
push buttons all land in ``respond_approval``). Mounted at /api/approval.

``api/clarify.py`` is the free-text twin of this module.
"""
import logging
import queue
import threading
import uuid

from api import sse
from api.helpers import bad, j

logger = logging.getLogger(__name__)

# The agent tree is optional: the two-container docker setup runs the WebUI
# without it, and then every command counts as approved.
try:
    from tools.approval import (
        approve_session,
        approve_permanent,
        save_permanent_allowlist,
        is_approved,
        _pending,
        _lock,
        _permanent_approved,
        resolve_gateway_approval,
        enable_session_yolo,
        disable_session_yolo,
        is_session_yolo_enabled,
    )
except ImportError:
    approve_session = lambda *a, **k: None
    approve_permanent = lambda *a, **k: None
    save_permanent_allowlist = lambda *a, **k: None
    is_approved = lambda *a, **k: True
    resolve_gateway_approval = lambda *a, **k: 0
    enable_session_yolo = lambda *a, **k: None
    disable_session_yolo = lambda *a, **k: None
    is_session_yolo_enabled = lambda *a, **k: False
    _pending = {}
    _lock = threading.Lock()
    _permanent_approved = set()


_approval_sse_subscribers: dict[str, list[queue.Queue]] = {}


def _approval_sse_subscribe(session_id: str) -> queue.Queue:
    q = queue.Queue(maxsize=16)
    with _lock:
        _approval_sse_subscribers.setdefault(session_id, []).append(q)
    return q


def _approval_sse_unsubscribe(session_id: str, q: queue.Queue) -> None:
    with _lock:
        subs = _approval_sse_subscribers.get(session_id)
        if subs and q in subs:
            subs.remove(q)
            if not subs:
                _approval_sse_subscribers.pop(session_id, None)


def _approval_sse_notify_locked(session_id: str, head: dict | None, total: int) -> None:
    """Push the queue's state to every SSE subscriber of a session.

    CALLER MUST HOLD `_lock`. `head` is the entry at the head of the queue (the
    one the UI shows, as `/api/approval/pending` does), NOT the just-appended
    one: with parallel approvals (#527) the new entry is at the tail. Pass
    `head=None, total=0` once the queue is empty so the client hides its card.
    """
    payload = {"pending": dict(head) if head else None, "pending_count": total}
    for q in _approval_sse_subscribers.get(session_id, ()):
        try:
            q.put_nowait(payload)
        except queue.Full:
            pass  # a slow subscriber drops events; the bounded queue caps memory


def _approval_sse_notify(session_id: str, head: dict | None, total: int) -> None:
    """`_approval_sse_notify_locked` for callers that don't hold `_lock`.

    Writers to the queue (submit_pending, respond_approval) MUST notify under
    the same lock as the write, or a later append's notify can overtake an
    earlier one's and deliver a stale `pending_count`.
    """
    with _lock:
        _approval_sse_notify_locked(session_id, head, total)


def _head_locked(sid: str) -> tuple[dict | None, int]:
    """(head entry, count) of a session's queue. Caller holds `_lock`.

    The queue is a list; an older agent stores a single dict instead."""
    q = _pending.get(sid)
    if isinstance(q, list):
        return (dict(q[0]) if q else None), len(q)
    if q:
        return dict(q), 1
    return None, 0


def submit_pending(session_key: str, approval: dict) -> None:
    """Append a pending approval to the per-session queue the UI reads.

    Each entry gets a stable approval_id so the respond endpoint can target it
    while several are queued, and the storage is a list so parallel tool calls
    each get their own slot (#527). Not the agent's own submit_pending, which
    overwrites the session's value with a single dict: the gateway's blocking
    path uses its own queues, and `_pending` only feeds the UI.
    """
    entry = dict(approval)
    entry.setdefault("approval_id", uuid.uuid4().hex)
    with _lock:
        queue_list = _pending.setdefault(session_key, [])
        if not isinstance(queue_list, list):
            _pending[session_key] = [queue_list]
            queue_list = _pending[session_key]
        queue_list.append(entry)
        _approval_sse_notify_locked(session_key, queue_list[0], len(queue_list))


def respond_approval(sid: str, choice: str, approval_id: str = "") -> int:
    """Answer a session's waiting approval. Returns how many waiting agent
    threads it released."""
    pending = None
    with _lock:
        queue_list = _pending.get(sid)
        if isinstance(queue_list, list):
            # The targeted entry; an unknown or missing id (old clients) takes the oldest.
            for i, entry in enumerate(queue_list):
                if approval_id and entry.get("approval_id") == approval_id:
                    pending = queue_list.pop(i)
                    break
            else:
                pending = queue_list.pop(0) if queue_list else None
            if not queue_list:
                _pending.pop(sid, None)
        elif queue_list:
            pending = _pending.pop(sid, None)
        # Show the next queued approval at once: without this a second parallel
        # one (#527) stays invisible until some later event.
        _approval_sse_notify_locked(sid, *_head_locked(sid))

    if pending:
        keys = pending.get("pattern_keys") or [pending.get("pattern_key", "")]
        if choice in ("once", "session"):
            for k in keys:
                approve_session(sid, k)
        elif choice == "always":
            for k in keys:
                approve_session(sid, k)
                approve_permanent(k)
            save_permanent_allowlist(_permanent_approved)
    # The agent thread is parked in the gateway queue's event.wait(); this wakes it.
    released = resolve_gateway_approval(sid, choice, resolve_all=False, approval_id=approval_id)
    # Its copies elsewhere (the Agents tab's request, a job card's buttons) go too.
    try:
        from api import jarvis_approvals
        jarvis_approvals.answered(sid, approval_id)
    except Exception:
        logger.debug("jarvis approval copies not settled", exc_info=True)
    return released


def set_yolo(sid: str, enabled: bool) -> None:
    """Session-wide auto-approve (#467). Turning it on also releases whatever
    the agent is already waiting on, so it doesn't stay stuck behind a card."""
    if not enabled:
        disable_session_yolo(sid)
        return
    enable_session_yolo(sid)
    try:
        with _lock:
            _pending.pop(sid, None)
    except Exception:
        pass
    resolve_gateway_approval(sid, "once", resolve_all=True)


def _handle_approval_pending(handler, sid: str):
    with _lock:
        head, total = _head_locked(sid)
    return j(handler, {"pending": head, "pending_count": total if head else 0})


def _handle_approval_sse_stream(handler, sid: str):
    """SSE: approval events the moment they arrive (the client polls if this fails)."""
    if not sid:
        return bad(handler, "session_id is required")
    # Subscribe AND snapshot under one _lock acquisition: snapshot-then-subscribe
    # loses an approval that lands in the gap (appended after the snapshot,
    # notified before we joined).
    q = queue.Queue(maxsize=16)
    with _lock:
        _approval_sse_subscribers.setdefault(sid, []).append(q)
        initial_pending, initial_count = _head_locked(sid)
    try:
        sse.open_stream(handler)
        sse.relay(handler, q, "approval",
                  greet=("initial", {"pending": initial_pending, "pending_count": initial_count}))
    finally:
        _approval_sse_unsubscribe(sid, q)
    return True


def _handle_approval_inject(handler, query):
    """Inject a fake pending approval -- loopback-only, used by automated tests."""
    sid = query.get("session_id", [""])[0]
    if not sid:
        return j(handler, {"error": "session_id required"}, status=400)
    key = query.get("pattern_key", ["test_pattern"])[0]
    submit_pending(sid, {
        "command": query.get("command", ["rm -rf /tmp/test"])[0],
        "pattern_key": key,
        "pattern_keys": [key],
        "description": "test pattern",
    })
    return j(handler, {"ok": True, "session_id": sid})


def _handle_approval_respond(handler, body):
    sid = body.get("session_id", "")
    if not sid:
        return bad(handler, "session_id is required")
    choice = body.get("choice", "deny")
    if choice not in ("once", "session", "always", "deny"):
        return bad(handler, f"Invalid choice: {choice}")
    respond_approval(sid, choice, body.get("approval_id", ""))
    return j(handler, {"ok": True, "choice": choice})


def route(req):
    h, sub = req.handler, req.sub
    if req.method == "GET":
        sid = req.query.get("session_id", [""])[0]
        if sub == "/pending":
            return _handle_approval_pending(h, sid)
        if sub == "/stream":
            return _handle_approval_sse_stream(h, sid)
        if sub == "/inject_test":
            if h.client_address[0] != "127.0.0.1":
                return j(h, {"error": "not found"}, status=404)
            return _handle_approval_inject(h, req.query)
    if req.method == "POST" and sub == "/respond":
        return _handle_approval_respond(h, req.body)
    return False
