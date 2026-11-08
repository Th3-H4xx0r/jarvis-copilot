"""Jarvis's own approval prompts as Agents requests.

A Jarvis turn that hits a dangerous command (or a send card) waits on the
gateway approval queue of its session. A Background job runs on a hidden worker
session nobody draws, so that prompt used to be invisible: the Agents tab only
showed "Needs approval" with no buttons. Every such prompt is now also an Agents
request (Allow / Always / Deny on the Agents screen, in "Needs you", on the push
and the Live Activity), and the job card carries it so the main chat can answer
it too. Whichever answer comes first wins; the others are cleared.

Every ask carries its gateway ``approval_id``, so an answer from any screen
releases exactly that ask. When the gateway is done with one (answered,
timed out, the turn stopped) it tells us (``tools.approval`` settled
listener) and every copy goes.

In memory only: a prompt lives exactly as long as the turn waiting on it.
"""
from __future__ import annotations

import logging
import threading
import uuid

log = logging.getLogger(__name__)

_LOCK = threading.Lock()
_OPEN: dict[str, list[tuple[str, dict]]] = {}   # session id -> [(fingerprint, data)], oldest first
_CHOICES = {"allow": "once", "always": "always", "deny": "deny"}


def _is_worker(sid: str) -> bool:
    return "~" in (sid or "")


def _watched(sid: str) -> bool:
    """A device has this chat open, so its own card is on a screen. A Background
    job's worker never is; a chat nobody has open (the phone in a pocket) gets
    the push too."""
    if _is_worker(sid):
        return False
    try:
        from api.session_events import SESSION_EVENTS
        return SESSION_EVENTS.subscriber_count(sid) > 0
    except Exception:  # noqa: BLE001
        return True


def _timeout() -> int:
    try:
        from tools.approval import _get_approval_config
        return int(_get_approval_config().get("gateway_timeout", 300) or 300)
    except Exception:  # noqa: BLE001
        return 300


def _is_send(data: dict) -> bool:
    return str(data.get("kind") or "") == "send"


def _summary(data: dict) -> str:
    desc = str(data.get("description") or "").strip()
    cmd = str(data.get("command") or "").strip()
    if _is_send(data):
        return (desc or cmd or "Send a message")[:200]
    if desc and cmd:
        return f"{desc}: {cmd}"[:200]
    return (cmd or desc or "Run a command")[:200]


def _tool(data: dict) -> str:
    return "send_message" if _is_send(data) else "terminal"


def _tool_input(data: dict) -> dict:
    return {"command": str(data.get("command") or _summary(data))}


def _key(sid: str) -> str:
    from agent.agent_engine_shim import session_key
    return session_key("server", "jarvis", sid, "")


def _fingerprint(sid: str, token: str, data: dict) -> str:
    """The same fingerprint the tracker gives the row's pending approval, so the
    Live Activity's buttons (which carry the row's) find this request."""
    try:
        from agent.agent_engine_shim import fingerprint
        return fingerprint(sid, token, _tool(data), _tool_input(data))
    except Exception:  # noqa: BLE001
        return f"jarvis:{sid}:{token}"


def _tracker():
    try:
        from agent.agent_tracking import tracker
        return tracker()
    except Exception:  # noqa: BLE001
        return None


def _mark_waiting(sid: str, data: dict) -> None:
    """The Agents row for this Jarvis session shows the exact prompt."""
    tr = _tracker()
    if tr is None:
        return
    try:
        tr.ingest(None, "permission", "jarvis", {
            "hook_event_name": "PermissionRequest", "session_id": sid, "cwd": "",
            "tool_name": _tool(data), "tool_input": _tool_input(data),
            "tool_use_id": data.get("_token") or ""})
    except Exception:  # noqa: BLE001
        log.debug("jarvis approval row not marked", exc_info=True)


def _settle_row(sid: str) -> None:
    tr = _tracker()
    if tr is None:
        return
    try:
        tr.settle(_key(sid))
    except Exception:  # noqa: BLE001
        log.debug("jarvis approval row not settled", exc_info=True)


def _note_job(sid: str, data: dict | None) -> None:
    if not _is_worker(sid):
        return
    try:
        from api import harness_runner
        harness_runner.note_worker_approval(sid, data)
    except Exception:  # noqa: BLE001
        log.debug("job card approval not updated", exc_info=True)


def _request(fp: str, sid: str, data: dict, *, quiet: bool) -> None:
    send = _is_send(data)
    try:
        from api import agent_hooks
        agent_hooks.on_agent_pending(None, {
            "fingerprint": fp, "kind": "permission", "agent": "jarvis",
            "session_id": sid, "cwd": "",
            "tool": _tool(data),
            "summary": _summary(data), "command": str(data.get("command") or ""),
            "can_always": (not send) and bool(data.get("pattern_keys") or data.get("pattern_key")),
            "ttl": _timeout() + 15,
            "quiet": quiet,
            "title": "Jarvis wants to send" if send else "Jarvis needs approval",
        })
    except Exception:  # noqa: BLE001
        log.debug("jarvis approval not announced", exc_info=True)


def announce(sid: str, data: dict) -> str:
    """A turn on ``sid`` is now waiting on this approval. Returns its fingerprint."""
    if not sid or not isinstance(data, dict):
        return ""
    _listen()
    token = uuid.uuid4().hex[:16]
    entry = dict(data)
    entry["_token"] = token
    entry["session_id"] = sid
    fp = _fingerprint(sid, token, entry)
    entry["fingerprint"] = fp
    with _LOCK:
        _OPEN.setdefault(sid, []).append((fp, entry))
    # A chat open on a screen already shows its own card there.
    _request(fp, sid, entry, quiet=_watched(sid))
    _mark_waiting(sid, entry)
    _note_job(sid, entry)
    return fp


def _drop(fp: str) -> None:
    try:
        from api import coding_permission as cp
        cp.drop_by_fingerprint(fp, None)
    except Exception:  # noqa: BLE001
        pass


def _pop(sid: str, approval_id: str = "") -> tuple[str, dict] | None:
    """The ask ``approval_id`` names (none if it isn't open), else the oldest."""
    with _LOCK:
        items = _OPEN.get(sid) or []
        if not items:
            return None
        if approval_id:
            idx = next((i for i, (_f, d) in enumerate(items)
                        if str(d.get("approval_id") or "") == approval_id), None)
            if idx is None:
                return None
        else:
            idx = 0
        item = items.pop(idx)
        if not items:
            _OPEN.pop(sid, None)
        return item


def _after_change(sid: str) -> None:
    """Point the Agents row and the job card at whatever is still waiting."""
    _settle_row(sid)
    with _LOCK:
        items = list(_OPEN.get(sid) or [])
    nxt = items[0] if items else None
    if nxt:
        _mark_waiting(sid, nxt[1])
    _note_job(sid, nxt[1] if nxt else None)


def answered(sid: str, approval_id: str = "") -> None:
    """Someone answered one prompt on ``sid`` (chat card, job card, Agents)."""
    item = _pop(sid, approval_id)
    if item is None:
        return
    _drop(item[0])
    _after_change(sid)


def _settled(sid, data) -> None:
    """The gateway is done with an ask (answered, timed out, turn stopped)."""
    approval_id = str((data or {}).get("approval_id") or "")
    if not approval_id:
        return
    answered(str(sid or ""), approval_id)


_listening = False


def _listen() -> None:
    global _listening
    if _listening:
        return
    try:
        from tools.approval import add_settled_listener
        add_settled_listener(_settled)
        _listening = True
    except Exception:  # noqa: BLE001
        log.debug("approval settled listener not registered", exc_info=True)


def clear(sid: str) -> None:
    """The turn on ``sid`` ended: nothing on it is waiting any more."""
    with _LOCK:
        items = _OPEN.pop(sid, None) or []
    for fp, _d in items:
        _drop(fp)
    if items:
        _after_change(sid)


def _find(fp) -> tuple[str, dict] | None:
    with _LOCK:
        for sid, items in _OPEN.items():
            for f, d in items:
                if f == fp:
                    return sid, d
    return None


def owns(fp) -> bool:
    return bool(fp) and _find(fp) is not None


def decide(fp: str, decision: str) -> bool:
    """An Agents decision (screen, push button, Live Activity) for a Jarvis prompt."""
    found = _find(fp)
    if found is None:
        return False
    sid, data = found
    choice = _CHOICES.get(str(decision or "").lower())
    if choice is None:
        # "ask" (answer it where it was asked): the request store has already
        # let go of it, so put it back — the turn is still waiting.
        _request(fp, sid, data, quiet=True)
        return True
    from api.approvals import respond_approval
    released = respond_approval(sid, choice, str(data.get("approval_id") or ""))
    # respond_approval settles the copies; an ask the gateway no longer has
    # (it ended a moment ago) is just retired.
    if _find(fp) is not None:
        answered(sid, str(data.get("approval_id") or ""))
    return bool(released)


def open_for(sid: str) -> list[dict]:
    with _LOCK:
        return [dict(d) for _f, d in (_OPEN.get(sid) or [])]


def _reset_for_tests() -> None:
    global _listening
    with _LOCK:
        _OPEN.clear()
    _listening = False
