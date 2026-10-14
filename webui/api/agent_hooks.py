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
import threading

from agent.agent_tracking import AgentTracker, set_tracker, tracker

log = logging.getLogger(__name__)

_SWEEP_EVERY = 1.0
_TURN_EVENTS = ("UserPromptSubmit", "Stop", "StopFailure", "PostToolUse", "SessionStart")
_state: dict = {"server": None, "stop": None}


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


def start_server_socket(tr: AgentTracker, path: str):
    """The hook socket for agents running on this host. Returns the HookServer."""
    from agent.agent_engine_shim import load_hook_server
    HookServer = load_hook_server()

    def ingest(kind, agent, payload):
        effects = tr.ingest(None, kind, agent, payload)
        _mark_transcript(payload)
        return effects

    server = HookServer(path, None, forward=lambda _f: None, ingest=ingest,
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
