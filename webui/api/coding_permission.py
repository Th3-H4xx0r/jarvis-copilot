"""In-memory pending permission-approval requests for the remote PreToolUse relay.

A coding session's ``PreToolUse`` hook (via ``jc-client coding-permission``)
POSTs a request; the server pushes an APNs alert to the user's phone and HOLDS
the request until the mobile app POSTs a verdict, which the hook (polling)
applies as the tool's ``permissionDecision``. Purely in-memory + TTL-bounded;
a missed/late verdict just times out, and the hook falls back to the local
prompt (``ask``) — so a lost request is never fail-open.
"""
from __future__ import annotations

import threading
import time
import uuid

_TTL = 150.0          # a pending request older than this is reaped
_MAX_PENDING = 200    # bound memory against a runaway/abusive producer
_LOCK = threading.Lock()
_PENDING: dict[str, dict] = {}   # request_id -> record


def _reap_locked(now: float) -> None:
    dead = [rid for rid, r in _PENDING.items() if now - r["created"] > _TTL]
    for rid in dead:
        _PENDING.pop(rid, None)


def create_request(*, tool: str, summary: str, session_id: str,
                   cwd: str) -> str:
    """Register a pending request and return its id."""
    rid = uuid.uuid4().hex
    now = time.time()
    with _LOCK:
        _reap_locked(now)
        if len(_PENDING) >= _MAX_PENDING:
            # Evict the oldest UNRESOLVED request — never drop a resolved-but-
            # not-yet-polled verdict out from under the waiting hook.
            unresolved = [k for k, r in _PENDING.items() if not r["resolved"]]
            victim = (min(unresolved, key=lambda k: _PENDING[k]["created"])
                      if unresolved else
                      min(_PENDING, key=lambda k: _PENDING[k]["created"]))
            _PENDING.pop(victim, None)
        _PENDING[rid] = {
            "created": now, "tool": tool, "summary": summary,
            "session_id": session_id, "cwd": cwd,
            "resolved": False, "decision": None, "reason": "", "message": "",
        }
    return rid


def resolve(request_id: str, *, decision: str, message: str = "") -> bool:
    """Record a verdict (``allow``/``deny``). A reply message on a deny becomes
    the instruction Claude reads (``reason``). Returns False if the request is
    unknown or already gone."""
    d = (decision or "").lower().strip()
    if d not in ("allow", "deny"):
        return False
    with _LOCK:
        r = _PENDING.get(request_id)
        if r is None:
            return False
        r["resolved"] = True
        r["decision"] = d
        r["message"] = (message or "").strip()
        if d == "deny" and r["message"]:
            r["reason"] = r["message"]
        return True


def poll(request_id: str) -> dict:
    """For the hook's jc-client poll. Returns ``{status: pending|resolved|
    expired, ...}``; a resolved request is consumed (delivered once)."""
    now = time.time()
    with _LOCK:
        _reap_locked(now)
        r = _PENDING.get(request_id)
        if r is None:
            return {"status": "expired"}
        if not r["resolved"]:
            return {"status": "pending"}
        out = {"status": "resolved", "decision": r["decision"],
               "reason": r["reason"], "message": r["message"]}
        _PENDING.pop(request_id, None)
        return out


def list_pending() -> list:
    """Unresolved requests (newest first) for the in-app approval card to render
    even if the push was missed."""
    now = time.time()
    with _LOCK:
        _reap_locked(now)
        items = [
            {"request_id": rid, "tool": r["tool"], "summary": r["summary"],
             "session_id": r["session_id"], "cwd": r["cwd"],
             "created": r["created"]}
            for rid, r in _PENDING.items() if not r["resolved"]
        ]
    items.sort(key=lambda x: x["created"], reverse=True)
    return items


def _reset_for_tests() -> None:
    with _LOCK:
        _PENDING.clear()
