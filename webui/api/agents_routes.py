"""``/api/coding/agents/*`` — the hook-tracked agent sessions, for the iPhone
Agents tab and the Mac island. Mounted inside the coding dispatcher
(``coding_routes.handle_coding_request``) so it shares its auth and wiring.

    GET  /agents/sessions             -> {sessions, usage, pending}
    GET  /agents/session?key=<key>    -> {session} (steps, last turn, diffs)
    POST /agents/instruction {key, text}
                                      -> {ok, via: "terminal"|"resume"}
    GET  /agents/usage                -> {claude, source}
"""
from __future__ import annotations

import logging

log = logging.getLogger(__name__)

_MAX_INSTRUCTION = 8000


def _ok(payload):
    return 200, payload


def _err(status, msg):
    return status, {"error": msg}


def _tracker():
    try:
        from agent.agent_tracking import tracker
        return tracker()
    except Exception:  # noqa: BLE001
        return None


def _remote_instructions() -> bool:
    """Code Master switch: may the phone continue a Mac session that isn't in
    tmux (``claude -p … --resume`` on the Mac)? Off unless turned on."""
    try:
        from api.coding_routes import _coding_settings, default_manager
        return bool(_coding_settings(default_manager("server").store).get("remote_instructions"))
    except Exception:  # noqa: BLE001
        return False


def _pending():
    try:
        from api import coding_permission
        return coding_permission.list_pending()
    except Exception:  # noqa: BLE001
        return []


def handle_agents_request(method, p, query, body, *, manager, manager_for_host=None):
    tr = _tracker()
    if p == "/agents/sessions" and method == "GET":
        return _ok({"sessions": tr.sessions() if tr else [],
                    "usage": tr.usage() if tr else None,
                    "pending": _pending()})
    if p == "/agents/session" and method == "GET":
        key = (query.get("key") or "").strip()
        session = tr.session(key) if (tr and key) else None
        if session is None:
            return _err(404, "no such agent session")
        return _ok({"session": session})
    if p == "/agents/usage" and method == "GET":
        return _ok({"claude": tr.usage() if tr else None})
    if p == "/agents/instruction" and method == "POST":
        return _instruction(tr, body, manager, manager_for_host)
    if p == "/agents/decide" and method == "POST":
        return _decide(body)
    return _err(404, "not found")


def _decide(body):
    """A decision keyed by the request's fingerprint (the Live Activity's buttons)."""
    from api import coding_permission
    fingerprint = str((body or {}).get("fingerprint") or "").strip()
    decision = str((body or {}).get("decision") or "").strip().lower()
    if not fingerprint or not decision:
        return _err(400, "fingerprint and decision are required")
    match = next((r for r in coding_permission.list_pending()
                  if r.get("fingerprint") == fingerprint), None)
    if match is None:
        return _err(404, "that request is no longer waiting")
    ok = coding_permission.resolve(match["request_id"], decision=decision,
                                   message=str((body or {}).get("message") or ""))
    return _ok({"ok": ok})


def _instruction(tr, body, manager, manager_for_host):
    key = str((body or {}).get("key") or "").strip()
    text = str((body or {}).get("text") or "").strip()
    if not key or not text:
        return _err(400, "key and text are required")
    if len(text) > _MAX_INSTRUCTION:
        return _err(400, "instruction too long")
    session = tr.session(key) if tr else None
    if session is None:
        return _err(404, "no such agent session")
    rid = session.get("coding_session_id")
    row = None
    if rid and manager is not None:
        try:
            row = manager.store.get_session(rid)
        except Exception:  # noqa: BLE001
            row = None
    if row and row.get("tmux_name"):
        host = row.get("host") or "server"
        mgr = manager_for_host(host) if manager_for_host else manager
        try:
            mgr.send_message(rid, text)
        except Exception as exc:  # noqa: BLE001
            return _err(502, f"could not type into the session: {exc}")
        return _ok({"ok": True, "via": "terminal"})
    device_id = session.get("device_id")
    if not device_id:
        return _err(409, "this session can't take instructions (no terminal to type into)")
    if not _remote_instructions():
        return _err(403, "turn on \"Instructions from the phone\" in Code Master settings first")
    from api import device_bridge
    sent = device_bridge.send_frame(device_id, {
        "type": "agent_instruction", "session_id": session.get("session_id") or "",
        "cwd": session.get("cwd") or "", "agent": session.get("agent") or "claude",
        "text": text})
    if not sent:
        return _err(503, "the Mac running this session is offline")
    return _ok({"ok": True, "via": "resume"})
