"""Hook-driven agent tracking wired into the webui: device events from a Mac and
the server's own hook socket both reach the tracker."""
from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import tempfile
import time

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import pytest  # noqa: E402

from agent.agent_tracking import AgentTracker, set_tracker, tracker  # noqa: E402
from agent.coding_session_db import CodingSessionStore  # noqa: E402
from api import agent_hooks  # noqa: E402


def _load_jc_hook():
    path = os.path.join(_REPO_ROOT, "desktop_client", "jc_client", "hook_relay", "jc_hook.py")
    spec = importlib.util.spec_from_file_location("jc_hook_for_tests", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def store(tmp_path):
    return CodingSessionStore(str(tmp_path / "c.db"))


@pytest.fixture(autouse=True)
def _no_tracker():
    set_tracker(None)
    yield
    set_tracker(None)


def test_device_event_reaches_the_tracker(store):
    set_tracker(AgentTracker(store))
    agent_hooks.on_agent_hook("d1", {"kind": "event", "agent": "claude", "payload": {
        "hook_event_name": "UserPromptSubmit", "session_id": "s", "cwd": "/Users/p/app",
        "prompt": "hi"}})
    s = tracker().sessions()
    assert len(s) == 1 and s[0]["state"] == "thinking" and s[0]["device_id"] == "d1"


def test_device_event_without_tracker_is_ignored():
    agent_hooks.on_agent_hook("d1", {"kind": "event", "payload": {"hook_event_name": "Stop"}})


def test_build_tracker_publishes_on_the_agents_topic(store, monkeypatch):
    sent = []
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "publish", lambda topic, data, exclude=None: sent.append(topic))
    monkeypatch.setattr(agent_hooks, "_live_push", lambda store: None)
    tr = agent_hooks.build_tracker(store)
    tr.ingest("d1", "event", "claude", {"hook_event_name": "SessionStart", "session_id": "s",
                                         "cwd": "/Users/p/app"})
    assert sent == ["agents"]


def test_server_hook_socket_end_to_end(store, allow_outbound_network):
    jc_hook = _load_jc_hook()
    tr = AgentTracker(store)
    d = tempfile.mkdtemp(dir="/tmp", prefix="jah")
    path = os.path.join(d, "a.sock")
    server = agent_hooks.start_server_socket(tr, path)
    try:
        out, code = jc_hook.main(["--socket", path], b'{"hook_event_name": "UserPromptSubmit",'
                                 b' "session_id": "srv", "cwd": "/root/app", "prompt": "go"}', {})
        assert (out, code) == ("", 0)
        end = time.time() + 2
        while not tr.sessions() and time.time() < end:
            time.sleep(0.01)
        s = tr.sessions()[0]
        assert (s["host"], s["state"], s["session_id"]) == ("server", "thinking", "srv")
        row = store.get_session(s["coding_session_id"])
        assert (row["host"], row["source"], row["activity_state"]) == ("server", "hook", "working")
    finally:
        server.close()
        shutil.rmtree(d, ignore_errors=True)


def test_an_approval_rings_the_phone_once(store, monkeypatch):
    """With phone approvals on, the actionable push is the one banner; the
    matrix "needs you" banner would be a second buzz (sweep finding). With
    them off, the matrix banner is the only signal and still goes."""
    from api import device_bridge
    import api.coding_routes as cr
    monkeypatch.setattr(device_bridge, "publish", lambda *a, **k: None)
    monkeypatch.setattr(agent_hooks, "_live_push", lambda store: None)
    sent = []
    monkeypatch.setattr(cr, "_dispatch_coding_notifications",
                        lambda store, event, row, cwd: sent.append(event) or {})
    tr = agent_hooks.build_tracker(store)
    perm = {"hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/Users/p/app",
            "tool_name": "Bash", "tool_use_id": "t1", "tool_input": {"command": "ls"}}
    monkeypatch.setattr(agent_hooks, "_remote_approvals", lambda: True)
    tr.ingest("d1", "permission", "claude", dict(perm))
    assert sent == []
    monkeypatch.setattr(agent_hooks, "_remote_approvals", lambda: False)
    tr.ingest("d1", "permission", "claude", dict(perm, session_id="s2", tool_use_id="t2"))
    assert sent == ["notification"]
    # An agent that only says so in a notification gets no actionable push: its banner stays.
    monkeypatch.setattr(agent_hooks, "_remote_approvals", lambda: True)
    tr.ingest("d1", "event", "gemini", {"hook_event_name": "Notification", "session_id": "g1", "cwd": "/Users/p/app",
                                        "notification_type": "permission_prompt", "message": "needs permission"})
    assert sent[-1] == "notification"
