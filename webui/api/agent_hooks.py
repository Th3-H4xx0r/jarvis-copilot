"""Hook-driven coding-agent tracking, wired into the webui.

Two inputs feed one ``AgentTracker`` (``agent/agent_tracking.py``):

* ``agent_hook`` device events — a Mac's jc-client forwards every frame its
  ``jc-hook`` relay sends it over the device bridge;
* the server's own hook socket (``$HERMES_HOME/agent-hook.sock``) for agents
  running on this host (Jarvis-launched tmux sessions).

The tracker's outputs reuse what the Coding Sessions UI already has: the
``agents`` bridge topic, the Live-Activity push + WebUI SSE nudge, and the
Code Master notification matrix.
"""
from __future__ import annotations

import logging
import os
import time
import threading

from agent.agent_tracking import AgentTracker, set_tracker, tracker

log = logging.getLogger(__name__)

_SWEEP_EVERY = 1.0
_TURN_EVENTS = ("UserPromptSubmit", "Stop", "StopFailure", "PostToolUse", "SessionStart")
_state: dict = {"server": None, "stop": None, "arbiter": None}


def socket_path() -> str:
    try:
        from jarviscopilot_constants import get_hermes_home
        home = str(get_hermes_home())
    except Exception:  # noqa: BLE001
        home = os.path.expanduser("~/.jarviscopilot")
    return os.path.join(home, "agent-hook.sock")


def _live_push(store) -> None:
    from api.coding_routes import _notify_webui, _push_coding_now
    _push_coding_now(store)
    _notify_webui()


def build_tracker(store) -> AgentTracker:
    def publish(topic, data):
        from api import device_bridge
        device_bridge.publish(topic, data)

    def notify(event, row, cwd):
        from api.coding_routes import _dispatch_coding_notifications
        _dispatch_coding_notifications(store, event=event, row=row, cwd=cwd)

    def dismissed(device_id, key):
        try:
            from api.coding_desktop import _is_dismissed
            return _is_dismissed(device_id, key)
        except Exception:  # noqa: BLE001
            return False

    return AgentTracker(store, publish=publish, notify=notify,
                        live_push=lambda: _live_push(store), is_dismissed=dismissed)


def _mark_transcript(payload) -> None:
    if payload.get("hook_event_name") not in _TURN_EVENTS:
        return
    try:
        from api.coding_desktop import mark_transcript_dirty
        mark_transcript_dirty(payload.get("session_id"))
    except Exception:  # noqa: BLE001
        pass


def on_agent_hook(device_id, data) -> None:
    """Device-event handler: one forwarded jc-hook frame from a paired device."""
    tr = tracker()
    if tr is None or not isinstance(data, dict):
        return
    payload = data.get("payload")
    if not isinstance(payload, dict):
        return
    try:
        from api.coding_desktop import note_device_reconnect
        note_device_reconnect(device_id)  # a live frame: the device is back
    except Exception:  # noqa: BLE001
        pass
    tr.ingest(device_id or None, str(data.get("kind") or "event"),
              str(data.get("agent") or "claude"), payload)
    _mark_transcript(payload)


def on_device_gone(device_id) -> None:
    tr = tracker()
    if tr is not None:
        tr.on_device_gone(device_id)


# ── approvals and questions held by a hook arbiter ───────────────────────────
# A Mac's jc-client (or this server's own arbiter) holds the waiting hook and
# announces it (agent_pending). The phone sees it through the existing
# /permission/* endpoints + an actionable push, and its decision is routed back
# to exactly that holder, carrying the request's fingerprint.

_AGENT_NAMES = {"claude": "Claude", "claude-desktop": "Claude", "codex": "Codex",
                "gemini": "Gemini", "cursor": "Cursor", "copilot": "Copilot",
                "antigravity": "Antigravity", "muse": "Muse", "opencode": "OpenCode",
                "amp": "Amp", "jarvis": "Jarvis"}


def _store():
    from api.coding_routes import default_manager
    return default_manager("server").store


def _settings() -> dict:
    try:
        from api.coding_routes import _coding_settings
        return _coding_settings(_store())
    except Exception:  # noqa: BLE001
        return {}


def _remote_approvals() -> bool:
    return bool(_settings().get("remote_approvals"))


def _config_frame(settings: dict) -> dict:
    return {"type": "agent_config",
            "remote_approvals": bool((settings or {}).get("remote_approvals")),
            "remote_instructions": bool((settings or {}).get("remote_instructions"))}


def _local_arbiter():
    return _state.get("arbiter")


def _project(cwd: str) -> str:
    return (cwd or "").rstrip("/").split("/")[-1] or "session"


def _push_agent_alert(*, title: str, body: str, data: dict, category: str) -> int:
    """An actionable banner to every paired phone. Returns how many it reached."""
    sent = 0
    try:
        from api import push as push_mod
        from api.pairing import list_devices
        devices = list_devices()
    except Exception:  # noqa: BLE001
        return 0
    for d in devices:
        try:
            token = (d.get("push_token") or "").strip()
            if not token or (d.get("push_kind") or "").strip().lower() != "apns":
                continue
            if not (d.get("kind") or "").strip().lower().startswith("mobile"):
                continue
            res = push_mod.send("apns", token, data,
                                alert={"title": title, "body": body, "category": category})
            if res.get("ok"):
                sent += 1
        except Exception:  # noqa: BLE001
            continue
    return sent


def _server_key(device_id, data) -> str:
    from agent.agent_engine_shim import session_key
    return session_key(device_id or "server", str(data.get("agent") or "claude"),
                       str(data.get("session_id") or ""), str(data.get("cwd") or ""))


def on_agent_pending(device_id, data) -> None:
    from api import coding_permission as cp
    if not isinstance(data, dict) or not data.get("fingerprint"):
        return
    kind = "ask" if data.get("kind") == "ask" else "permission"
    cwd = str(data.get("cwd") or "")
    rid = cp.create_request(
        tool=str(data.get("tool") or "tool"), summary=str(data.get("summary") or ""),
        session_id=str(data.get("session_id") or ""), cwd=cwd,
        fingerprint=str(data["fingerprint"]), device_id=device_id or None, kind=kind,
        questions=data.get("questions") if kind == "ask" else None,
        can_always=bool(data.get("can_always")), agent=str(data.get("agent") or "claude"),
        key=_server_key(device_id, data), command=str(data.get("command") or ""))
    agent_key = _server_key(device_id, data)
    who = _AGENT_NAMES.get(str(data.get("agent") or "claude"), "Claude")
    project = _project(cwd)
    if kind == "ask":
        qs = data.get("questions") or []
        first = qs[0].get("question") if qs and isinstance(qs[0], dict) else ""
        title, body, category = f"{who} has a question", f"{project}: {first}".strip(": "), "AGENT_QUESTION"
    else:
        title, body, category = f"{who} needs approval", f"{project}: {data.get('summary') or ''}", "PERMISSION_APPROVAL"
    _push_agent_alert(title=title, body=body[:240], category=category,
                      data={"type": "coding_permission", "request_id": rid, "kind": kind,
                            "agent_key": agent_key,
                            "fingerprint": data["fingerprint"], "session_id": data.get("session_id") or "",
                            "tool": data.get("tool") or "", "summary": (data.get("summary") or "")[:200],
                            "project": project, "can_always": bool(data.get("can_always"))})


_COUNTED_DECISIONS = {"allow", "always", "deny", "answer"}


def _settled_key(device_id, data) -> str:
    """The tracker's key for a settled request. The arbiter names the session by
    its own engine's key (``local|<agent>|<session>``); the server keys the same
    session by the device it came from."""
    parts = str(data.get("key") or "").split("|", 2)
    if len(parts) == 3 and parts[2]:
        from agent.agent_engine_shim import session_key
        return session_key(device_id or "server", parts[1], parts[2], "")
    return _server_key(device_id, data)


def on_agent_settled(device_id, data) -> None:
    from api import coding_permission as cp
    if not isinstance(data, dict) or not data.get("fingerprint"):
        return
    cp.drop_by_fingerprint(str(data["fingerprint"]), device_id or None)
    tr = tracker()
    if tr is not None:
        key = _settled_key(device_id, data)
        tr.settle(key, str(data["fingerprint"]))
        decision = str(data.get("decision") or "")
        if decision in _COUNTED_DECISIONS and data.get("reason") == "decided":
            tr.record_decision(key, str(data.get("kind") or "permission"), decision)


def maybe_send_recap(store, now: float, push=None) -> bool:
    """Monday's recap notification: once a week, and only for a week with work in it."""
    from agent import agent_recap
    last = store.get_setting("agents_recap_sent")
    if not agent_recap.recap_due(now, last if isinstance(last, (int, float)) else None):
        return False
    since = now - agent_recap.WEEK
    recap = agent_recap.build_recap(store.list_agent_turns(since=since),
                                    store.list_agent_decisions(since=since), now=now)
    store.set_setting("agents_recap_sent", now)
    line = agent_recap.summary_line(recap)
    if not line:
        return False
    if push is None:
        from api.coding_routes import _push_device_alert
        push = _push_device_alert
    push("Your week with the agents", line, {"type": "agents_recap"})
    return True


def on_agent_hello(device_id, _data=None) -> None:
    from api import device_bridge
    device_bridge.send_frame(device_id, _config_frame(_settings()))


def broadcast_config(settings: dict) -> None:
    """The Code Master settings changed: tell every connected device."""
    from api import device_bridge
    frame = _config_frame(settings)
    for device_id in device_bridge.connected_device_ids():
        try:
            device_bridge.send_frame(device_id, dict(frame))
        except Exception:  # noqa: BLE001
            continue


def _route_decision(record, decision, message, answers) -> bool:
    fingerprint = record.get("fingerprint")
    device_id = record.get("device_id")
    if device_id:
        from api import device_bridge
        return bool(device_bridge.send_frame(device_id, {
            "type": "agent_decision", "fingerprint": fingerprint, "decision": decision,
            "message": message or "", "answers": answers}))
    arb = _local_arbiter()
    if arb is None:
        return False
    return bool(arb.decide(fingerprint, decision, message=message or None, answers=answers))


def _install_router() -> None:
    from api import coding_permission as cp
    cp.set_router(_route_decision)


_install_router()


def start_server_socket(tr: AgentTracker, path: str):
    """The hook socket for agents running on this host. Returns the HookServer."""
    from agent.agent_engine_shim import load_arbiter, load_hook_server
    HookServer = load_hook_server()
    Arbiter = load_arbiter()

    def ingest(kind, agent, payload):
        effects = tr.ingest(None, kind, agent, payload)
        _mark_transcript(payload)
        return effects

    def local_event(frame):
        name, data = frame.get("name"), frame.get("data") or {}
        if name == "agent_pending":
            on_agent_pending(None, data)
        elif name == "agent_settled":
            on_agent_settled(None, data)

    arbiter = Arbiter(send_up=local_event, gate=_remote_approvals)
    _state["arbiter"] = arbiter
    server = HookServer(path, None, forward=lambda _f: None, ingest=ingest, arbiter=arbiter,
                        on_usage=lambda p: tr.ingest(None, "statusline", "claude", p),
                        host="server", sweep_every=0)
    server.start()
    return server


def start(store) -> None:
    """Called once at webui boot."""
    if _state["stop"] is not None:
        return
    tr = build_tracker(store)
    set_tracker(tr)
    from api import device_bridge
    device_bridge.on_device_event("agent_hook", on_agent_hook)
    device_bridge.on_device_event("agent_pending", on_agent_pending)
    device_bridge.on_device_event("agent_settled", on_agent_settled)
    device_bridge.on_device_event("agent_hello", on_agent_hello)
    try:
        _state["server"] = start_server_socket(tr, socket_path())
    except Exception as exc:  # noqa: BLE001 — device events still work without it
        print(f"[!!] WARNING: agent hook socket failed to start: {exc}", flush=True)
    stop = threading.Event()
    _state["stop"] = stop

    def sweep_loop():
        while not stop.wait(_SWEEP_EVERY):
            try:
                tr.sweep()
            except Exception:  # noqa: BLE001
                log.debug("agent tracker sweep failed", exc_info=True)
            try:
                maybe_send_recap(store, time.time())
            except Exception:  # noqa: BLE001
                log.debug("agent recap push failed", exc_info=True)

    threading.Thread(target=sweep_loop, daemon=True, name="agent-sweep").start()


def stop() -> None:
    if _state["stop"] is not None:
        _state["stop"].set()
        _state["stop"] = None
    if _state["server"] is not None:
        try:
            _state["server"].close()
        except Exception:  # noqa: BLE001
            pass
        _state["server"] = None
