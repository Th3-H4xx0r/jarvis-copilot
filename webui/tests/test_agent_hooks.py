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


class _FakeTimer:
    made: list = []

    def __init__(self, delay, fn, args=()):
        self.delay, self.fn, self.args, self.daemon = delay, fn, args, False
        _FakeTimer.made.append(self)

    def start(self):
        pass

    def fire(self):
        self.fn(*self.args)


def _hook(device, sid):
    agent_hooks.on_agent_hook(device, {"kind": "event", "agent": "claude", "payload": {
        "hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/Users/p/app",
        "prompt": "hi"}})


def test_a_device_that_stays_away_loses_its_sessions(store, monkeypatch):
    """A bridge drop is usually a blip: the device's tracked sessions go only once
    it hasn't come back within the grace."""
    monkeypatch.setattr(agent_hooks.threading, "Timer", _FakeTimer)
    _FakeTimer.made = []
    set_tracker(AgentTracker(store))
    _hook("d1", "a")
    _hook("d2", "b")
    agent_hooks._on_device_disconnect("d1")
    assert _FakeTimer.made[-1].delay == agent_hooks._GONE_GRACE
    _FakeTimer.made[-1].fire()
    assert [s["session_id"] for s in tracker().sessions()] == ["b"]


def test_a_device_back_within_the_grace_keeps_its_sessions(store, monkeypatch):
    monkeypatch.setattr(agent_hooks.threading, "Timer", _FakeTimer)
    monkeypatch.setattr(agent_hooks, "_config_frame", lambda _s: {})
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "send_frame", lambda *a, **k: True)
    _FakeTimer.made = []
    set_tracker(AgentTracker(store))
    _hook("d1", "a")
    agent_hooks._on_device_disconnect("d1")
    _hook("d1", "a")                      # a live hook frame: it's back
    _FakeTimer.made[-1].fire()
    agent_hooks._on_device_disconnect("d1")
    agent_hooks.on_agent_hello("d1")      # its hello on reconnect also counts
    _FakeTimer.made[-1].fire()
    assert [s["session_id"] for s in tracker().sessions()] == ["a"]


def test_an_old_timer_never_drops_a_device_that_dropped_again(store, monkeypatch):
    monkeypatch.setattr(agent_hooks.threading, "Timer", _FakeTimer)
    _FakeTimer.made = []
    set_tracker(AgentTracker(store))
    _hook("d1", "a")
    agent_hooks._on_device_disconnect("d1")
    first = _FakeTimer.made[-1]
    _hook("d1", "a")
    agent_hooks._on_device_disconnect("d1")   # dropped again: a newer timer owns it
    first.fire()
    assert len(tracker().sessions()) == 1
    _FakeTimer.made[-1].fire()
    assert tracker().sessions() == []


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


# ── per-agent Live Activities ────────────────────────────────────────────────

class _CountingPusher:
    def __init__(self):
        self.ticks = 0

    def tick(self, force=False):
        self.ticks += 1
        return 0


@pytest.fixture
def counting_pusher():
    from agent import agent_la_push
    p = _CountingPusher()
    agent_la_push.set_pusher(p)
    yield p
    agent_la_push.set_pusher(None)


def _eventually(cond, timeout=2.0):
    deadline = time.time() + timeout
    while not cond() and time.time() < deadline:
        time.sleep(0.01)
    return cond()


def test_a_tracker_change_reaches_the_agent_activities(store, monkeypatch, counting_pusher):
    import api.coding_routes as cr
    monkeypatch.setattr(cr, "_push_coding_now", lambda store: None)
    monkeypatch.setattr(cr, "_notify_webui", lambda: None)
    agent_hooks._live_push(store)
    assert _eventually(lambda: counting_pusher.ticks == 1)


def test_a_held_request_reaches_the_agent_activities_at_once(monkeypatch, counting_pusher):
    """The Allow / Deny buttons need the request the arbiter holds — it is announced
    after the hook state, so the activity is refreshed when it arrives."""
    from api import coding_permission as cp
    monkeypatch.setattr(agent_hooks, "_push_agent_alert", lambda **kw: 0)
    agent_hooks.on_agent_pending("d1", {"fingerprint": "fp1", "tool": "Bash", "cwd": "/x/app",
                                        "session_id": "s", "agent": "claude"})
    assert _eventually(lambda: counting_pusher.ticks == 1)
    cp.drop_by_fingerprint("fp1", "d1")


def test_the_la_pusher_reads_the_code_master_settings(store):
    store.set_setting("notifications", {"agent_live": {"idle_minutes": 10}})
    p = agent_hooks.build_la_pusher(store)
    assert p.snapshot()["settings"]["idle_minutes"] == 10


def test_agent_la_ticks_never_block_the_device_event_thread():
    """A tick holds the pusher while it talks to APNs (10 s timeouts): the
    device-event thread — door alarm, hooks — must hand it off, not wait. Ticks
    asked for while one runs coalesce into one more."""
    import threading
    from agent import agent_la_push

    release, started = threading.Event(), threading.Event()

    class SlowPusher:
        ticks = 0

        def tick(self, force=False):
            SlowPusher.ticks += 1
            started.set()
            release.wait(5)
            return 0

    agent_la_push.set_pusher(SlowPusher())
    try:
        t0 = time.time()
        agent_hooks._agent_la_tick()
        assert started.wait(2)
        for _ in range(5):
            agent_hooks._agent_la_tick()
        assert time.time() - t0 < 1.0
        release.set()
        assert _eventually(lambda: SlowPusher.ticks == 2)
        time.sleep(0.2)
        assert SlowPusher.ticks == 2
    finally:
        release.set()
        agent_la_push.set_pusher(None)


def test_the_la_pusher_skips_a_tick_when_the_settings_cant_be_read(store, monkeypatch):
    """A locked database must not read as "no settings" (= every agent on): with
    agent activities turned off, a locked read must not start pushing again."""
    from agent import agent_la_push
    store.set_setting("notifications", {"agent_live": {"enabled": False}})
    store.set_setting(agent_la_push.REGISTRY_KEY, {"ph": {"activities": {"claude": "ACT"}}})
    p = agent_hooks.build_la_pusher(store)
    sent = []
    p._sender = lambda token, cs, **kw: sent.append(kw.get("event")) or {"ok": True}
    p._tracked = lambda: [{"key": "k", "agent": "claude", "state": "working", "project": "app",
                           "last_event_at": time.time(), "started_at": time.time()}]
    real_get = store.get_setting

    def locked(key, default=None):
        if key == "notifications":
            raise RuntimeError("database is locked")
        return real_get(key, default)
    monkeypatch.setattr(store, "get_setting", locked)
    p.tick()
    assert sent == []
