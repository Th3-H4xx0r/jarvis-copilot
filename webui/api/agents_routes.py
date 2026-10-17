"""``/api/coding/agents/*`` — the hook-tracked agent sessions, for the iPhone
Agents tab and the Mac island. Mounted inside the coding dispatcher
(``coding_routes.handle_coding_request``) so it shares its auth and wiring.

    GET  /agents/sessions             -> {sessions, usage, pending}
    GET  /agents/session?key=<key>    -> {session} (steps, last turn, diffs)
    POST /agents/instruction {key, text}
                                      -> {ok, via: "queued"|"typed"|"chat"}
    GET  /agents/usage                -> {claude, codex}
    GET  /agents/recap?days=7&tz=-300 -> the week's numbers (agent/agent_recap.py)
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
    """Code Master switch: may the phone send messages into a Mac session (typed
    into its terminal, or handed over at its next Stop)? Off unless turned on."""
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
    """``manager`` holds the shared store; ``manager_for_host`` is unused (old callers)."""
    tr = _tracker()
    if p == "/agents/sessions" and method == "GET":
        return _ok({"sessions": tr.sessions() if tr else [],
                    "usage": tr.usage() if tr else None,
                    "usage_codex": tr.usage("codex") if tr else None,
                    "pending": _pending()})
    if p == "/agents/session" and method == "GET":
        key = (query.get("key") or "").strip()
        session = tr.session(key) if (tr and key) else None
        if session is None:
            return _err(404, "no such agent session")
        return _ok({"session": session})
    if p == "/agents/usage" and method == "GET":
        return _ok({"claude": tr.usage() if tr else None, "codex": tr.usage("codex") if tr else None})
    if p == "/agents/instruction" and method == "POST":
        return _instruction(tr, body)
    if p == "/agents/decide" and method == "POST":
        return _decide(body)
    if p == "/agents/focus" and method == "POST":
        only = bool((body or {}).get("only_waiting"))
        import time as _time
        manager.store.set_setting("agents_focus", {"only_waiting": only, "at": _time.time()})
        return _ok({"ok": True, "only_waiting": only})
    if p == "/agents/recap" and method == "GET":
        return _recap(manager.store, query)
    if p in _V2_ROUTES:
        return _v2(method, p, query, body or {})
    if p == "/agents/history" and method == "GET":
        import time as _time
        turns = manager.store.list_agent_turns(since=_time.time() - 7 * 86400)
        turns.sort(key=lambda t: t.get("ended_at") or 0, reverse=True)
        return _ok({"turns": turns[:200]})
    return _err(404, "not found")


# ── the merged Agents tab (webui/api/agents_core.py) ─────────────────────────
_V2_ROUTES = frozenset({"/agents/list", "/agents/messages", "/agents/send", "/agents/continue",
                        "/agents/stop", "/agents/resume", "/agents/launch",
                        "/agents/card/dismiss", "/agents/terminal/start",
                        "/agents/project/sync"})
_MAX_CONTINUE = 20


def _core():
    try:
        from api.agents_core import core
        return core()
    except Exception:  # noqa: BLE001
        return None


def _int(v):
    try:
        return int(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _result(out: dict):
    return (200, out) if out.get("ok") else (409, out)


def _v2(method, p, query, body):
    c = _core()
    if c is None:
        return _err(503, "the Agents service isn't ready yet")
    ckey = str((query or {}).get("ckey") or body.get("ckey") or "").strip()
    if p == "/agents/list" and method == "GET":
        return _ok(c.list_payload())
    if p == "/agents/messages" and method == "GET":
        page = c.messages(ckey, after=_int(query.get("after")) or 0,
                          before=_int(query.get("before")), limit=_int(query.get("limit")),
                          lite=str(query.get("lite") or "1") != "0")
        return _ok(page) if page is not None else _err(404, "no such session")
    if method != "POST":
        return _err(405, "method not allowed")
    if p == "/agents/send":
        text = str(body.get("text") or "").strip()
        if not ckey or not text:
            return _err(400, "ckey and text are required")
        if len(text) > _MAX_INSTRUCTION:
            return _err(400, "message too long")
        delivery = c.handoff.send(ckey, text)
        c._changed()
        return (409 if delivery["state"] == "failed" else 200), {"delivery": delivery}
    if p == "/agents/continue":
        ckeys = [str(k) for k in (body.get("ckeys") or ([ckey] if ckey else []))][:_MAX_CONTINUE]
        to = str(body.get("to") or "server")
        if not ckeys or to not in ("server", "mac"):
            return _err(400, "ckeys and to=server|mac are required")
        results = {}
        for k in ckeys:
            results[k] = (c.handoff.continue_on_server(k, confirm_offline=bool(body.get("confirm_offline")))
                          if to == "server" else c.handoff.continue_on_mac(k))
        c._changed()
        return _ok({"results": results})
    if p == "/agents/stop":
        return _result(c.stop(ckey))
    if p == "/agents/resume":
        return _result(c.resume(ckey, str(body.get("where") or "server")))
    if p == "/agents/launch":
        return _result(c.launch(body))
    if p == "/agents/card/dismiss":
        device_id = str(body.get("device_id") or "").strip()
        if not device_id:
            return _err(400, "device_id is required")
        c.dismiss(device_id, body.get("ckeys"))
        return _ok({"ok": True})
    if p == "/agents/project/sync":
        pid = str(body.get("project_id") or "").strip()
        if not pid:
            return _err(400, "project_id is required")
        c.set_project_sync(pid, bool(body.get("on")))
        c._changed()
        return _ok({"ok": True})
    if p == "/agents/terminal/start":
        target = c.terminal_argv(ckey)
        if target is None:
            return _err(409, "this session has no terminal to open")
        import hashlib
        from api.terminal import start_argv_terminal
        argv, cwd = target
        tid = "agent-" + hashlib.sha1(ckey.encode()).hexdigest()[:12]
        start_argv_terminal(tid, argv, cwd=cwd, rows=_int(body.get("rows")) or 24,
                            cols=_int(body.get("cols")) or 80)
        return _ok({"terminal_id": tid})
    return _err(404, "not found")


def _recap(store, query):
    import time as _time
    from agent import agent_recap

    def num(name, default, lo, hi):
        try:
            v = int((query or {}).get(name, default))
        except (TypeError, ValueError):
            return default
        return max(lo, min(hi, v))

    days = num("days", 7, 1, 31)
    tz = num("tz", 0, -14 * 60, 14 * 60)
    now = _time.time()
    since = now - days * 86400
    recap = agent_recap.build_recap(store.list_agent_turns(since=since),
                                    store.list_agent_decisions(since=since),
                                    now=now, days=days, tz_offset_min=tz)
    recap["summary"] = agent_recap.summary_line(recap)
    return _ok(recap)


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


_WORKING = {"working", "thinking", "approval", "question"}
# The agents whose Stop hook collects a queued message (jc_hook _STOP_DELIVERY_AGENTS).
_STOP_HAND_OFF_AGENTS = ("claude", "claude-desktop")
_TERMINAL_NAMES = {"vscode": "VS Code", "apple_terminal": "Terminal", "ghostty": "Ghostty",
                   "wezterm": "WezTerm", "warpterminal": "Warp", "cursor": "Cursor", "zed": "Zed"}


def _terminal_name(terminal: dict) -> str:
    tp = str((terminal or {}).get("term_program") or "").lower()
    return _TERMINAL_NAMES.get(tp, tp or "its terminal")


def _start_jarvis_turn(session_id: str, text: str) -> dict:
    from api.routes import start_chat_turn
    return start_chat_turn(session_id, text)


def _jarvis_instruction(session, text):
    """A Jarvis chat: the message goes into that chat as your next turn."""
    sid = session.get("session_id") or ""
    where = (session.get("project") or "").split("·")[-1].strip() or "another app"
    try:
        out = _start_jarvis_turn(sid, text)
    except KeyError:
        return _err(409, f"Jarvis can't continue this chat from here (it started in {where}); reply there.")
    if isinstance(out, dict) and out.get("error"):
        if int(out.get("_status") or 0) == 409:
            return _err(409, "Jarvis is still answering in that chat; send it again when it's done.")
        return _err(502, str(out["error"]))
    return _ok({"ok": True, "via": "chat"})


def _instruction(tr, body):
    """The phone's next instruction for a session (the older path; the Agents tab
    sends through ``/agents/send``).

    Never a background `claude --resume` of a live session: that forks the
    conversation into a second copy that acts on its own. Instead a working
    session is handed it when it finishes its current step (the Mac's Stop
    hook), an idle one in iTerm on the Mac gets it typed in, and a Jarvis chat
    gets it as a chat turn."""
    key = str((body or {}).get("key") or "").strip()
    text = str((body or {}).get("text") or "").strip()
    if not key or not text:
        return _err(400, "key and text are required")
    if len(text) > _MAX_INSTRUCTION:
        return _err(400, "instruction too long")
    session = tr.session(key) if tr else None
    if session is None:
        return _err(404, "no such agent session")
    if (session.get("agent") or "") == "jarvis":
        return _jarvis_instruction(session, text)
    device_id = session.get("device_id")
    if not device_id:
        return _err(409, "this session can't take instructions (no terminal to type into)")
    if not _remote_instructions():
        return _err(403, "turn on \"Instructions from the phone\" in Code Master settings first")
    terminal = dict(session.get("terminal") or {})
    agent = session.get("agent") or "claude"
    working = (session.get("state") or "") in _WORKING
    typable = bool(terminal.get("iterm"))
    if working and agent in _STOP_HAND_OFF_AGENTS:
        mode, via = "queue", "queued"
    elif typable:
        # Idle, or an agent without a Stop hand-off whose terminal buffers what's typed.
        mode, via = "type", "typed"
    elif working:
        return 409, {"error": f"This session is working in {_terminal_name(terminal)}, which Jarvis can't "
                              "type into, and it can't be handed a message mid-turn. Send it when it's "
                              "done, or type it there.",
                     "reason": "busy_untypable"}
    else:
        return 409, {"error": f"This session is waiting at its prompt in {_terminal_name(terminal)}, which "
                              "Jarvis can't type into. Type it there, or send it while the session is working.",
                     "reason": "idle_untypable"}
    from api import device_bridge
    sent = device_bridge.send_frame(device_id, {
        "type": "agent_instruction", "mode": mode, "session_id": session.get("session_id") or "",
        "cwd": session.get("cwd") or "", "agent": session.get("agent") or "claude",
        "text": text, "terminal": terminal})
    if not sent:
        return _err(503, "the Mac running this session is offline")
    return _ok({"ok": True, "via": via})
