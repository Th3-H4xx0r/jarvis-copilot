"""Per-agent Live Activities over /api/coding: the settings live in the Code Master
document (agent_live), the phone reads its activities from /agent-la/state and
registers its push tokens with /agent-la/token."""
from __future__ import annotations

import json

import pytest

from agent import agent_la_push
from api import coding_routes as cr
from api.coding_routes import handle_coding_request


class FakeStore:
    def __init__(self):
        self._settings = {}
        self.sessions = []

    def get_setting(self, key, default=None):
        return json.loads(json.dumps(self._settings[key])) if key in self._settings else default

    def set_setting(self, key, value):
        self._settings[key] = json.loads(json.dumps(value))

    def list_sessions(self, **kw):
        return [dict(s) for s in self.sessions]

    def list_projects(self):
        return []

    def list_la_tokens(self):
        return []


class FakeManager:
    def __init__(self):
        self.store = FakeStore()


class Sender:
    def __init__(self):
        self.calls = []

    def __call__(self, token, cs, **kw):
        self.calls.append((kw.get("event"), token, cs))
        return {"ok": True}


@pytest.fixture
def pusher_env(monkeypatch):
    """A process pusher wired like agent_hooks.start does, with a fake sender."""
    m = FakeManager()
    box = {"sessions": []}
    sender = Sender()
    p = agent_la_push.AgentLaPusher(
        m.store, tracked=lambda: box["sessions"],
        settings=lambda: cr._coding_settings(m.store)["agent_live"], sender=sender)
    agent_la_push.set_pusher(p)
    monkeypatch.setattr(cr, "_tick_agent_las_soon", lambda: p.tick())
    yield m, box, sender
    agent_la_push.set_pusher(None)


def _session(key, agent="claude", state="working"):
    import time
    return {"key": key, "agent": agent, "state": state, "last_event_at": time.time(),
            "project": "app", "step": "Bash: ls", "pending": None, "started_at": time.time()}


# ── settings ───────────────────────────────────────────────────────────────

def test_settings_carry_agent_live_with_defaults():
    _, body = handle_coding_request("GET", "/settings", None, manager=FakeManager())
    live = body["settings"]["agent_live"]
    assert live["enabled"] is True and live["actions"] is True and live["idle_minutes"] == 30
    assert all(live["agents"].values()) and "claude" in live["agents"]


def test_merge_keeps_agent_live_and_rejects_junk():
    merged = cr._merge_notify_settings({"agent_live": {"idle_minutes": 10, "enabled": "x",
                                                       "agents": {"codex": False}}})
    assert merged["agent_live"]["idle_minutes"] == 10
    assert merged["agent_live"]["enabled"] is True
    assert merged["agent_live"]["agents"]["codex"] is False


def test_a_partial_agent_live_save_keeps_everything_else():
    """The Dynamic Island tab saves only agent_live: the notification matrix, the
    other switches and the agent toggles it didn't send must survive."""
    m = FakeManager()
    handle_coding_request("POST", "/settings", {
        "events": {"finished": {"telegram": False}}, "remote_approvals": True,
        "agent_live": {"agents": {"codex": False}, "idle_minutes": 60}}, manager=m)
    _, body = handle_coding_request("POST", "/settings", {"agent_live": {"enabled": False}},
                                    manager=m)
    s = body["settings"]
    assert s["events"]["finished"]["telegram"] is False
    assert s["remote_approvals"] is True
    assert s["agent_live"]["enabled"] is False
    assert s["agent_live"]["agents"]["codex"] is False and s["agent_live"]["idle_minutes"] == 60


def test_an_app_that_doesnt_know_agent_live_keeps_it():
    m = FakeManager()
    handle_coding_request("POST", "/settings", {"agent_live": {"actions": False}}, manager=m)
    _, body = handle_coding_request("POST", "/settings", {"usage_display": False}, manager=m)
    assert body["settings"]["agent_live"]["actions"] is False


def test_saving_settings_reapplies_them_to_the_activities(pusher_env):
    m, box, sender = pusher_env
    box["sessions"] = [_session("a")]
    handle_coding_request("POST", "/agent-la/token",
                          {"kind": "activity", "agent": "claude", "token": "ACT", "device_id": "ph"},
                          manager=m)
    handle_coding_request("POST", "/settings", {"agent_live": {"enabled": False}}, manager=m)
    assert ("end", "ACT") in [(e, t) for e, t, _ in sender.calls]


# ── /agent-la/state ───────────────────────────────────────────────────────

def test_state_lists_the_activities_the_phone_should_show(pusher_env):
    m, box, _ = pusher_env
    box["sessions"] = [_session("a", "claude"), _session("b", "codex", state="approval")]
    status, body = handle_coding_request("GET", "/agent-la/state", None, manager=m)
    assert status == 200
    agents = {a["agent"]: a for a in body["activities"]}
    assert set(agents) == {"claude", "codex"}
    assert agents["codex"]["state"]["waiting"] == 1
    assert body["settings"]["enabled"] is True


def test_state_without_a_running_tracker_still_answers():
    agent_la_push.set_pusher(None)
    status, body = handle_coding_request("GET", "/agent-la/state", None, manager=FakeManager())
    assert status == 200 and body["activities"] == [] and "settings" in body


# ── /agent-la/token ───────────────────────────────────────────────────────

def test_a_start_token_is_stored_per_device(pusher_env):
    m, _, _ = pusher_env
    status, _ = handle_coding_request("POST", "/agent-la/token",
                                      {"kind": "start", "token": "S1", "device_id": "ph"}, manager=m)
    assert status == 200
    assert m.store.get_setting(agent_la_push.REGISTRY_KEY)["ph"]["start"] == "S1"


def test_an_activity_token_gets_the_current_state_at_once(pusher_env):
    m, box, sender = pusher_env
    box["sessions"] = [_session("a", "gemini")]
    status, body = handle_coding_request(
        "POST", "/agent-la/token",
        {"kind": "activity", "agent": "gemini", "token": "G1", "device_id": "ph"}, manager=m)
    assert status == 200 and body["ok"] is True
    assert sender.calls[-1][:2] == ("update", "G1")


def test_a_dismissed_activity_is_forgotten(pusher_env):
    m, box, _ = pusher_env
    box["sessions"] = [_session("a")]
    handle_coding_request("POST", "/agent-la/token",
                          {"kind": "activity", "agent": "claude", "token": "A1", "device_id": "ph"},
                          manager=m)
    handle_coding_request("POST", "/agent-la/token",
                          {"kind": "activity", "agent": "claude", "token": "A1", "device_id": "ph",
                           "ended": True, "dismissed": True}, manager=m)
    reg = m.store.get_setting(agent_la_push.REGISTRY_KEY)
    assert "claude" not in reg["ph"]["activities"]


def test_a_device_turning_live_activities_off_is_forgotten(pusher_env):
    m, _, _ = pusher_env
    handle_coding_request("POST", "/agent-la/token",
                          {"kind": "start", "token": "S1", "device_id": "ph"}, manager=m)
    handle_coding_request("POST", "/agent-la/token",
                          {"kind": "device", "device_id": "ph", "ended": True}, manager=m)
    assert "ph" not in m.store.get_setting(agent_la_push.REGISTRY_KEY)


def test_token_route_rejects_a_bad_request(pusher_env):
    m, _, _ = pusher_env
    status, _ = handle_coding_request("POST", "/agent-la/token", {"kind": "activity"}, manager=m)
    assert status == 400
    status, _ = handle_coding_request("POST", "/agent-la/token",
                                      {"kind": "activity", "agent": "nope", "token": "x"}, manager=m)
    assert status == 400
