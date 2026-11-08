"""Clarify prompt state for the WebUI.

This mirrors the approval flow structure, but the response is a free-form
clarification string instead of an approval decision. Mounted at /api/clarify.
"""

from __future__ import annotations

import queue
import threading
import time
from typing import Optional

from api import sse
from api.helpers import bad, j


DEFAULT_TIMEOUT_SECONDS = 120
_lock = threading.Lock()
_pending: dict[str, dict] = {}
_gateway_queues: dict[str, list] = {}
_gateway_notify_cbs: dict[str, object] = {}

# ── SSE subscriber registry ─────────────────────────────────────────────
_clarify_sse_subscribers: dict[str, list[queue.Queue]] = {}


class _ClarifyEntry:
    """One pending clarify request inside a session."""

    __slots__ = ("event", "data", "result")

    def __init__(self, data: dict):
        self.event = threading.Event()
        self.data = data
        self.result: Optional[str] = None


def register_gateway_notify(session_key: str, cb) -> None:
    """Register a per-session callback for sending clarify requests to the UI."""
    with _lock:
        _gateway_notify_cbs[session_key] = cb


def _clear_queue_locked(session_key: str) -> list[_ClarifyEntry]:
    entries = _gateway_queues.pop(session_key, [])
    _pending.pop(session_key, None)
    return entries


def unregister_gateway_notify(session_key: str) -> None:
    """Unregister the per-session callback and unblock any waiting clarify prompt."""
    with _lock:
        _gateway_notify_cbs.pop(session_key, None)
        entries = _clear_queue_locked(session_key)
    for entry in entries:
        entry.event.set()


def clear_pending(session_key: str) -> int:
    """Clear any pending clarify prompts for the session without removing the callback."""
    with _lock:
        entries = _clear_queue_locked(session_key)
    for entry in entries:
        entry.event.set()
    return len(entries)


def _with_timeout_metadata(data: dict) -> dict:
    item = dict(data or {})
    requested_at = float(item.get("requested_at") or time.time())
    timeout_seconds = int(item.get("timeout_seconds") or DEFAULT_TIMEOUT_SECONDS)
    expires_at = float(item.get("expires_at") or requested_at + timeout_seconds)
    item["requested_at"] = requested_at
    item["timeout_seconds"] = timeout_seconds
    item["expires_at"] = expires_at
    return item


def _clarify_sse_notify(session_id: str, head: dict | None, total: int) -> None:
    """Push a clarify event to all SSE subscribers for a session."""
    payload = {"pending": dict(head) if head else None, "pending_count": total}
    for q in _clarify_sse_subscribers.get(session_id, ()):
        try:
            q.put_nowait(payload)
        except queue.Full:
            pass  # drop if subscriber is slow


def sse_subscribe(session_id: str) -> queue.Queue:
    """Register a bounded Queue for SSE push to a given session."""
    q: queue.Queue = queue.Queue(maxsize=16)
    with _lock:
        _clarify_sse_subscribers.setdefault(session_id, []).append(q)
    return q


def sse_unsubscribe(session_id: str, q: queue.Queue) -> None:
    """Remove a subscriber Queue; clean up empty session entries."""
    with _lock:
        subs = _clarify_sse_subscribers.get(session_id)
        if subs:
            try:
                subs.remove(q)
            except ValueError:
                pass
            if not subs:
                _clarify_sse_subscribers.pop(session_id, None)


def submit_pending(session_key: str, data: dict) -> _ClarifyEntry:
    """Queue a pending clarify request and notify the UI callback if registered."""
    data = _with_timeout_metadata(data)
    with _lock:
        gw_queue = _gateway_queues.setdefault(session_key, [])
        # De-duplicate while unresolved: if the most recent pending clarify is
        # semantically identical, reuse it instead of stacking duplicates.
        if gw_queue:
            last = gw_queue[-1]
            if (
                str(last.data.get("question", "")) == str(data.get("question", ""))
                and list(last.data.get("choices_offered") or [])
                == list(data.get("choices_offered") or [])
            ):
                entry = last
                cb = _gateway_notify_cbs.get(session_key)
                # Keep _pending aligned to the oldest unresolved entry.
                _pending[session_key] = gw_queue[0].data
                if cb:
                    try:
                        cb(dict(entry.data))
                    except Exception:
                        pass
                return entry

        entry = _ClarifyEntry(data)
        gw_queue.append(entry)
        _pending[session_key] = gw_queue[0].data
        cb = _gateway_notify_cbs.get(session_key)
        # Notify SSE subscribers from inside _lock for ordering guarantees.
        _clarify_sse_notify(session_key, dict(gw_queue[0].data), len(gw_queue))
    if cb:
        try:
            cb(data)
        except Exception:
            pass
    return entry


def get_pending(session_key: str) -> dict | None:
    """Return the oldest pending clarify request for this session, if any."""
    with _lock:
        queue = _gateway_queues.get(session_key) or []
        if queue:
            return dict(queue[0].data)
        pending = _pending.get(session_key)
        return dict(pending) if pending else None


def has_pending(session_key: str) -> bool:
    with _lock:
        return bool(_gateway_queues.get(session_key))


def resolve_clarify(session_key: str, response: str, resolve_all: bool = False) -> int:
    """Resolve the oldest pending clarify request for a session."""
    with _lock:
        q = _gateway_queues.get(session_key)
        if not q:
            _pending.pop(session_key, None)
            return 0
        entries = list(q) if resolve_all else [q.pop(0)]
        if q:
            _pending[session_key] = q[0].data
            _clarify_sse_notify(session_key, dict(q[0].data), len(q))
        else:
            _clear_queue_locked(session_key)
            _clarify_sse_notify(session_key, None, 0)
    count = 0
    for entry in entries:
        entry.result = response
        entry.event.set()
        count += 1
    return count


# ── HTTP: mounted at /api/clarify ─────────────────────────────────────────

def _handle_clarify_sse_stream(handler, sid: str):
    """SSE: clarify events the moment they arrive (the client polls if this fails)."""
    if not sid:
        return bad(handler, "session_id is required")
    # Subscribe AND snapshot under one _lock acquisition, as the approval stream
    # does. Not via get_pending(): it takes the non-reentrant _lock itself.
    q = queue.Queue(maxsize=16)
    initial_pending = None
    initial_count = 0
    with _lock:
        _clarify_sse_subscribers.setdefault(sid, []).append(q)
        gw_q = _gateway_queues.get(sid) or []
        if gw_q:
            initial_pending = dict(gw_q[0].data)
            initial_count = len(gw_q)
        else:
            _legacy = _pending.get(sid)
            if _legacy:
                initial_pending = dict(_legacy)
                initial_count = 1
    try:
        sse.open_stream(handler)
        sse.relay(handler, q, "clarify",
                  greet=("initial", {"pending": initial_pending, "pending_count": initial_count}))
    finally:
        sse_unsubscribe(sid, q)
    return True


def _handle_clarify_inject(handler, query):
    """Inject a fake pending clarify prompt -- loopback-only, used by automated tests."""
    sid = query.get("session_id", [""])[0]
    if not sid:
        return j(handler, {"error": "session_id required"}, status=400)
    submit_pending(sid, {
        "question": query.get("question", ["Which option?"])[0],
        "choices_offered": query.get("choices", []),
        "session_id": sid,
        "kind": "clarify",
    })
    return j(handler, {"ok": True, "session_id": sid})


def _handle_clarify_respond(handler, body):
    sid = body.get("session_id", "")
    if not sid:
        return bad(handler, "session_id is required")
    response = body.get("response")
    if response is None:
        response = body.get("answer")
    if response is None:
        response = body.get("choice")
    response = str(response or "").strip()
    if not response:
        return bad(handler, "response is required")
    resolve_clarify(sid, response, resolve_all=False)
    return j(handler, {"ok": True, "response": response})


def route(req):
    h, sub = req.handler, req.sub
    if req.method == "GET":
        sid = req.query.get("session_id", [""])[0]
        if sub == "/pending":
            return j(h, {"pending": get_pending(sid)})
        if sub == "/stream":
            return _handle_clarify_sse_stream(h, sid)
        if sub == "/inject_test":
            if h.client_address[0] != "127.0.0.1":
                return j(h, {"error": "not found"}, status=404)
            return _handle_clarify_inject(h, req.query)
    if req.method == "POST" and sub == "/respond":
        return _handle_clarify_respond(h, req.body)
    return False
