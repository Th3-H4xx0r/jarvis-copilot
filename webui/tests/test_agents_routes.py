"""/api/coding/agents/* — what the iPhone Agents tab and the Mac island read."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import pytest  # noqa: E402

from agent.agent_tracking import AgentTracker, set_tracker  # noqa: E402
from agent.coding_session_db import CodingSessionStore  # noqa: E402
from api import coding_permission as cp  # noqa: E402
from api.coding_routes import handle_coding_request  # noqa: E402


class Mgr:
    def __init__(self, store):
        self.store = store
        self.sent = []

    def send_message(self, sid, text):
        self.sent.append((sid, text))


@pytest.fixture
def env(tmp_path, monkeypatch):
    store = CodingSessionStore(str(tmp_path / "c.db"))
    tr = AgentTracker(store)
    set_tracker(tr)
    cp._reset_for_tests()
    frames = []
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "send_frame",
                        lambda d, f: frames.append((d, f)) or True)
    mgr = Mgr(store)
    yield store, tr, mgr, frames
    set_tracker(None)
    cp._reset_for_tests()


def ev(name, sid="s1", cwd="/Users/p/code/app", **kw):
    p = {"hook_event_name": name, "session_id": sid, "cwd": cwd}
    p.update(kw)
    return p


def call(method, path, body=None, mgr=None):
    return handle_coding_request(method, path, body, manager=mgr,
                                 manager_for_host=lambda host: mgr)


def test_sessions_lists_tracked_sessions_with_pending_and_usage(env):
    store, tr, mgr, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="hi"))
    tr.ingest("d1", "statusline", "claude", {"rate_limits": {
        "five_hour": {"used_percentage": 30, "resets_at": 9e9}}})
    status, body = call("GET", "/agents/sessions", mgr=mgr)
    assert status == 200
    assert body["sessions"][0]["state"] == "thinking"
    assert body["usage"]["five_hour"]["used_percentage"] == 30
    assert body["pending"] == []
    assert body["usage_codex"] is None
    tr.ingest("d1", "statusline", "codex", {"rate_limits": {
        "seven_day": {"used_percentage": 3, "resets_at": 9e9}}})
    _, body = call("GET", "/agents/sessions", mgr=mgr)
    assert body["usage_codex"]["seven_day"]["used_percentage"] == 3
    _, usage = call("GET", "/agents/usage", mgr=mgr)
    assert usage["codex"]["seven_day"]["used_percentage"] == 3


def test_session_detail_has_the_whole_turn(env):
    store, tr, mgr, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="fix the build"))
    key = tr.sessions()[0]["key"]
    from urllib.parse import quote
    status, body = call("GET", "/agents/session?key=" + quote(key), mgr=mgr)
    assert status == 200 and body["session"]["turn"]["prompt"] == "fix the build"
    status, _ = call("GET", "/agents/session?key=nope", mgr=mgr)
    assert status == 404


def test_instruction_to_a_tmux_session_types_into_it(env):
    store, tr, mgr, frames = env
    pid = store.get_or_create_project_for_path(repo_path="/Users/p/code/app", host="desktop",
                                               device_id="d1")
    rid = store.create_session(project_id=pid, host="desktop", cwd="/Users/p/code/app",
                               branch=None, tmux_name="2", source="discovered-tmux", title="2",
                               device_id="d1", external=True, status="running")
    tr.ingest("d1", "event", "claude", ev("Stop", tmux_session="2"))
    key = tr.sessions()[0]["key"]
    status, body = call("POST", "/agents/instruction", {"key": key, "text": "now run the tests"},
                        mgr=mgr)
    assert status == 200 and body["via"] == "terminal"
    assert mgr.sent == [(rid, "now run the tests")]
    assert frames == []


def test_instruction_to_a_plain_terminal_session_goes_to_the_mac(env, monkeypatch):
    store, tr, mgr, frames = env
    import api.agents_routes as ar
    monkeypatch.setattr(ar, "_remote_instructions", lambda: True)
    tr.ingest("d1", "event", "claude", ev("Stop"))
    key = tr.sessions()[0]["key"]
    status, body = call("POST", "/agents/instruction", {"key": key, "text": "continue"}, mgr=mgr)
    assert status == 200 and body["via"] == "resume"
    assert frames == [("d1", {"type": "agent_instruction", "session_id": "s1",
                              "cwd": "/Users/p/code/app", "agent": "claude", "text": "continue"})]


def test_instruction_needs_the_switch_for_plain_terminal_sessions(env, monkeypatch):
    store, tr, mgr, frames = env
    import api.agents_routes as ar
    monkeypatch.setattr(ar, "_remote_instructions", lambda: False)
    tr.ingest("d1", "event", "claude", ev("Stop"))
    key = tr.sessions()[0]["key"]
    status, body = call("POST", "/agents/instruction", {"key": key, "text": "go"}, mgr=mgr)
    assert status == 403 and frames == []


def test_instruction_validation(env):
    _, _, mgr, _ = env
    assert call("POST", "/agents/instruction", {"key": "x", "text": ""}, mgr=mgr)[0] == 400
    assert call("POST", "/agents/instruction", {"key": "x", "text": "hi"}, mgr=mgr)[0] == 404


def test_without_a_tracker_the_list_is_empty(env):
    set_tracker(None)
    status, body = call("GET", "/agents/sessions", mgr=env[2])
    assert status == 200 and body["sessions"] == []


def test_decide_by_fingerprint_reaches_the_waiting_request(env, monkeypatch):
    _, _, mgr, frames = env
    from api import agent_hooks
    agent_hooks.on_agent_pending("d1", {"fingerprint": "fp9", "kind": "permission",
                                        "agent": "claude", "session_id": "s1", "cwd": "/w",
                                        "tool": "Bash", "summary": "Bash: ls"})
    status, body = call("POST", "/agents/decide", {"fingerprint": "fp9", "decision": "allow"},
                        mgr=mgr)
    assert status == 200 and body["ok"] is True
    assert frames[-1][1]["fingerprint"] == "fp9" and frames[-1][1]["decision"] == "allow"
    status, _ = call("POST", "/agents/decide", {"fingerprint": "gone", "decision": "deny"},
                     mgr=mgr)
    assert status == 404


def test_focus_switch_is_stored(env):
    store, _, mgr, _ = env
    status, body = call("POST", "/agents/focus", {"only_waiting": True}, mgr=mgr)
    assert status == 200 and body["only_waiting"] is True
    assert store.get_setting("agents_focus")["only_waiting"] is True
    call("POST", "/agents/focus", {"only_waiting": False}, mgr=mgr)
    assert store.get_setting("agents_focus")["only_waiting"] is False


def test_history_lists_recent_turns_newest_first(env):
    store, tr, mgr, _ = env
    import time as _t
    now = _t.time()
    store.insert_agent_turn(key="k", agent="claude", project="old", started_at=now - 9 * 86400,
                            ended_at=now - 9 * 86400 + 60)
    store.insert_agent_turn(key="k", agent="claude", project="a", started_at=now - 600, ended_at=now - 500)
    store.insert_agent_turn(key="k", agent="codex", project="b", started_at=now - 300, ended_at=now - 200)
    status, body = call("GET", "/agents/history", mgr=mgr)
    assert status == 200
    assert [t["project"] for t in body["turns"]] == ["b", "a"]
