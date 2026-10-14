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


_ROUTER = None  # fn(record, decision, message, answers) -> bool, set by api.agent_hooks
_PERMISSION_DECISIONS = ("allow", "deny", "always", "ask")
_QUESTION_DECISIONS = ("answer", "ask")


def set_router(fn) -> None:
    """Where a decision for a hook-held request goes (the owning Mac, or the
    server's own arbiter). Requests without a fingerprint keep the old poll flow."""
    global _ROUTER
    _ROUTER = fn


def create_request(*, tool: str, summary: str, session_id: str,
                   cwd: str, fingerprint: str | None = None,
                   device_id: str | None = None, kind: str = "permission",
                   questions: list | None = None, can_always: bool = False,
                   agent: str = "claude", key: str = "", command: str = "") -> str:
    """Register a pending request and return its id. A request carrying a
    ``fingerprint`` (held by a hook arbiter) is registered once: announcing
    the same one again returns the existing id."""
    rid = uuid.uuid4().hex
    now = time.time()
    with _LOCK:
        _reap_locked(now)
        if fingerprint:
            for old_rid, r in _PENDING.items():
                if r.get("fingerprint") == fingerprint and not r["resolved"]:
                    return old_rid
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
            "fingerprint": fingerprint, "device_id": device_id, "kind": kind,
            "questions": questions, "can_always": bool(can_always), "agent": agent,
            "key": key, "command": command,
        }
    return rid


def drop_by_fingerprint(fingerprint: str, device_id: str | None = None) -> bool:
    """The hook that held this request settled it (answered elsewhere, timed
    out, went away): remove its card. Only the owning device may drop it."""
    with _LOCK:
        for rid, r in list(_PENDING.items()):
            if r.get("fingerprint") == fingerprint and (r.get("device_id") or None) == (device_id or None):
                _PENDING.pop(rid, None)
                return True
    return False


def resolve(request_id: str, *, decision: str, message: str = "", answers=None) -> bool:
    """Record a verdict. A hook-held request (it has a fingerprint) is routed
    to whoever holds it and removed; the legacy relay keeps ``allow``/``deny``
    for its poll, where a reply message on a deny becomes the instruction
    Claude reads (``reason``). Returns False if the request is unknown, gone,
    or the decision doesn't fit it (a question can't be "allowed")."""
    d = (decision or "").lower().strip()
    with _LOCK:
        r = _PENDING.get(request_id)
        if r is None:
            return False
        if r.get("fingerprint"):
            allowed = _QUESTION_DECISIONS if r.get("kind") == "ask" else _PERMISSION_DECISIONS
            if d not in allowed or _ROUTER is None:
                return False
            _PENDING.pop(request_id, None)
            record = dict(r)
        else:
            record = None
    if record is not None:
        try:
            return bool(_ROUTER(record, d, (message or "").strip(), answers))
        except Exception:
            return False
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
             "created": r["created"], "fingerprint": r.get("fingerprint"),
             "kind": r.get("kind") or "permission", "device_id": r.get("device_id"),
             "questions": r.get("questions"), "can_always": bool(r.get("can_always")),
             "agent": r.get("agent") or "claude", "key": r.get("key") or "",
             "command": r.get("command") or "",
             "project": (r["cwd"] or "").rstrip("/").split("/")[-1] or "session"}
            for rid, r in _PENDING.items() if not r["resolved"]
        ]
    items.sort(key=lambda x: x["created"], reverse=True)
    return items


def _reset_for_tests() -> None:
    with _LOCK:
        _PENDING.clear()
