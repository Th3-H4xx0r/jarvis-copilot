"""Server-side agent tracking: hook events from every host → session rows,
pushes and notifications. Hooks are the source of truth; a session outside
tmux becomes a live row instead of a history entry."""
import pytest

from agent.agent_tracking import AgentTracker
from agent.coding_session_db import CodingSessionStore


class Clock:
    def __init__(self, t=2_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def env(tmp_path):
    store = CodingSessionStore(str(tmp_path / "c.db"))
    calls = {"publish": [], "notify": [], "push": 0}
    clock = Clock()
    tr = AgentTracker(
        store,
        publish=lambda topic, data: calls["publish"].append((topic, data)),
        notify=lambda event, row, cwd: calls["notify"].append((event, (row or {}).get("id"), cwd)),
        live_push=lambda: calls.__setitem__("push", calls["push"] + 1),
        clock=clock)
    return store, tr, calls, clock


def ev(name, sid="s1", cwd="/Users/p/code/app", **kw):
    p = {"hook_event_name": name, "session_id": sid, "cwd": cwd}
    p.update(kw)
    return p


def test_hook_only_session_becomes_a_live_row(env):
    store, tr, calls, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="go",
                                          term_program="Apple_Terminal"))
    rows = store.list_sessions(device_id="d1")
    assert len(rows) == 1
    r = rows[0]
    assert (r["host"], r["status"], r["activity_state"]) == ("desktop", "running", "working")
    assert r["claude_session_id"] == "s1" and r["external"] == 1
    assert r["source"] == "discovered-transcript"
    assert store.get_project(r["project_id"])["repo_path"] == "/Users/p/code/app"
    assert calls["push"] == 1


def test_tmux_session_joins_its_discovered_row_and_fixes_the_csid(env):
    store, tr, _, _ = env
    pid = store.get_or_create_project_for_path(repo_path="/Users/p/code/app", host="desktop",
                                               device_id="d1")
    rid = store.create_session(project_id=pid, host="desktop", cwd="/Users/p/code/app",
                               branch=None, tmux_name="2", source="discovered-tmux", title="2",
                               device_id="d1", external=True, status="running",
                               claude_session_id="guessed")
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="real", prompt="x",
                                          tmux_session="2"))
    assert len(store.list_sessions(device_id="d1")) == 1
    r = store.get_session(rid)
    assert r["claude_session_id"] == "real" and r["activity_state"] == "working"


def test_existing_transcript_row_is_reused(env):
    store, tr, _, _ = env
    pid = store.get_or_create_project_for_path(repo_path="/Users/p/code/app", host="desktop",
                                               device_id="d1")
    rid = store.create_session(project_id=pid, host="desktop", cwd="/Users/p/code/app",
                               branch=None, tmux_name=None, source="discovered-transcript",
                               title="old", device_id="d1", external=True, status="idle",
                               claude_session_id="s1")
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    assert [r["id"] for r in store.list_sessions(device_id="d1")] == [rid]
    assert store.get_session(rid)["status"] == "running"


def test_server_host_session_joins_by_tmux_name(env):
    store, tr, _, _ = env
    rid = store.create_session(project_id=None, host="server", cwd="/root/app", branch=None,
                               tmux_name="jc-abc", source="chat", title="t", status="running")
    tr.ingest(None, "event", "claude", ev("UserPromptSubmit", cwd="/root/app", prompt="x",
                                          tmux_session="jc-abc"))
    assert store.get_session(rid)["activity_state"] == "working"
    assert store.get_session(rid)["claude_session_id"] == "s1"


def test_idle_prompt_never_notifies_and_stop_notifies_once(env):
    _, tr, calls, clock = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    tr.ingest("d1", "event", "claude", ev("Notification", notification_type="idle_prompt"))
    assert calls["notify"] == []
    clock.t += 120
    tr.ingest("d1", "event", "claude", ev("Stop", last_assistant_message="done"))
    assert [c[0] for c in calls["notify"]] == ["stop"]


def test_a_quick_reply_does_not_ring_the_phone(env):
    """Back-and-forth in a session you're sitting at shouldn't buzz the phone on
    every answer: "finished" is for turns that ran a while."""
    _, tr, calls, clock = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="hi"))
    clock.t += 8
    tr.ingest("d1", "event", "claude", ev("Stop", last_assistant_message="hello"))
    assert calls["notify"] == []
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="do the long thing"))
    clock.t += 300
    tr.ingest("d1", "event", "claude", ev("Stop", last_assistant_message="done"))
    assert [c[0] for c in calls["notify"]] == ["stop"]


def test_approval_maps_to_waiting(env):
    store, tr, calls, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    tr.ingest("d1", "permission", "claude", ev("PermissionRequest", tool_name="Bash",
                                               tool_use_id="t", tool_input={"command": "ls"}))
    assert store.list_sessions(device_id="d1")[0]["activity_state"] == "waiting"
    assert [c[0] for c in calls["notify"]] == ["notification"]


def test_publishes_compact_sessions_on_the_agents_topic(env):
    _, tr, calls, _ = env
    tr.ingest("d1", "event", "claude", ev("PreToolUse", tool_name="Bash", tool_use_id="t",
                                          tool_input={"command": "make"}))
    topic, data = calls["publish"][-1]
    assert topic == "agents"
    s = data["sessions"][0]
    assert s["state"] == "working" and s["step"] == "Bash: make"
    assert "turn" not in s  # the list stays small; details come from the session endpoint


def test_live_push_only_on_activity_change(env):
    _, tr, calls, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    tr.ingest("d1", "event", "claude", ev("PreToolUse", tool_name="Read", tool_use_id="a",
                                          tool_input={"file_path": "/a"}))
    tr.ingest("d1", "event", "claude", ev("PostToolUse", tool_name="Read", tool_use_id="a",
                                          tool_input={"file_path": "/a"}))
    assert calls["push"] == 1


def test_device_gone_drops_its_live_sessions(env):
    store, tr, _, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    tr.ingest("d2", "event", "claude", ev("UserPromptSubmit", sid="other", prompt="y"))
    tr.on_device_gone("d1")
    assert [s["host"] for s in tr.sessions()] == ["d2"]
    r = store.list_sessions(device_id="d1")[0]
    assert (r["status"], r["activity_state"]) == ("idle", None)


def test_hook_fresh_expires(env):
    store, tr, _, clock = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    rid = store.list_sessions(device_id="d1")[0]["id"]
    assert tr.hook_fresh(rid) is True
    clock.t += 31 * 60
    assert tr.hook_fresh(rid) is False
    assert tr.hook_fresh("cs_unknown") is False


def test_home_directory_session_gets_no_row(env, monkeypatch):
    store, tr, _, _ = env
    monkeypatch.setattr("agent.agent_tracking._dangerous_cwd", lambda p: p == "/Users/p")
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", cwd="/Users/p", prompt="x"))
    assert store.list_sessions(device_id="d1") == []
    assert tr.sessions()[0]["state"] == "thinking"


def test_restart_restores_sessions(env):
    store, tr, _, clock = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="survive"))
    tr2 = AgentTracker(store, clock=clock)
    s = tr2.sessions()[0]
    assert s["state"] == "thinking"
    assert tr2.session(s["key"])["turn"]["prompt"] == "survive"


def test_finished_turn_is_recorded_for_the_recap(env):
    store, tr, _, _ = env
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", prompt="x"))
    inp = {"file_path": "/a.py", "old_string": "a", "new_string": "b\nc"}
    tr.ingest("d1", "event", "claude", ev("PostToolUse", tool_name="Edit", tool_use_id="e",
                                          tool_input=inp))
    tr.ingest("d1", "event", "claude", ev("PostToolUse", tool_name="Bash", tool_use_id="b",
                                          tool_input={"command": "ls"}))
    tr.ingest("d1", "event", "claude", ev("Stop"))
    turns = store.list_agent_turns(since=0)
    assert len(turns) == 1
    t = turns[0]
    assert (t["agent"], t["project"], t["files"], t["added"], t["removed"], t["commands"]) == \
        ("claude", "app", 1, 2, 1, 1)


def test_statusline_updates_usage(env):
    _, tr, calls, _ = env
    tr.ingest("d1", "statusline", "claude", {"session_id": "s", "rate_limits": {
        "five_hour": {"used_percentage": 40, "resets_at": 2_000_900},
        "seven_day": {"used_percentage": 5, "resets_at": 2_300_000}}})
    u = tr.usage()
    assert u["five_hour"]["used_percentage"] == 40
    assert u["source"] == "d1"


def test_usage_from_many_reports_never_steps_back(env):
    """Two Macs (or one with stale sessions) report out of order: the phone
    sees the highest for the window, not whichever came last."""
    _, tr, _, _ = env
    for dev, pct in (("d1", 20), ("d2", 17), ("d1", 19)):
        tr.ingest(dev, "statusline", "claude", {"rate_limits": {
            "five_hour": {"used_percentage": pct, "resets_at": 2_000_900}}})
    assert tr.usage()["five_hour"]["used_percentage"] == 20
    tr.ingest("d2", "statusline", "claude", {"rate_limits": {
        "five_hour": {"used_percentage": 1, "resets_at": 2_018_900}}})
    assert tr.usage()["five_hour"]["used_percentage"] == 1


def test_codex_usage_is_kept_apart_from_claude(env):
    _, tr, _, _ = env
    tr.ingest("d1", "statusline", "claude", {"rate_limits": {
        "five_hour": {"used_percentage": 40, "resets_at": 2_000_900}}})
    tr.ingest("d1", "statusline", "codex", {"rate_limits": {
        "seven_day": {"used_percentage": 12, "resets_at": 2_300_000}}, "plan": "plus"})
    assert tr.usage()["five_hour"]["used_percentage"] == 40
    codex = tr.usage("codex")
    assert codex["seven_day"]["used_percentage"] == 12 and codex["plan"] == "plus"
    assert codex["five_hour"] is None


def test_jarvis_own_runs_show_but_never_notify_or_make_rows(env):
    """Jarvis already tells you about its own replies; its runs only appear live."""
    store, tr, calls, _ = env
    tr.ingest(None, "event", "jarvis", {"hook_event_name": "UserPromptSubmit", "session_id": "j1",
                                        "cwd": "", "prompt": "hi", "jc_project": "Jarvis · webui"})
    tr.ingest(None, "event", "jarvis", {"hook_event_name": "Stop", "session_id": "j1", "cwd": "",
                                        "last_assistant_message": "hello"})
    assert calls["notify"] == []
    assert store.list_sessions() == []
    assert any(s["agent"] == "jarvis" for s in tr.engine.sessions())


def test_two_claudes_in_one_tmux_session_keep_their_own_rows(env):
    """Two windows of tmux session "work": the second Claude must not take
    over the first one's row (sweep finding)."""
    store, tr, _, _ = env
    pid = store.get_or_create_project_for_path(repo_path="/Users/p/code/app", host="desktop",
                                               device_id="d1")
    rid = store.create_session(project_id=pid, host="desktop", cwd="/Users/p/code/app",
                               branch=None, tmux_name="work", source="discovered-tmux", title="work",
                               device_id="d1", external=True, status="running",
                               claude_session_id="guessed")
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="A", prompt="x", tmux_session="work"))
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="B", prompt="y", tmux_session="work"))
    a = next(s for s in tr.sessions() if s["session_id"] == "A")
    b = next(s for s in tr.sessions() if s["session_id"] == "B")
    assert a["coding_session_id"] == rid
    assert b["coding_session_id"] and b["coding_session_id"] != rid
    assert store.get_session(rid)["claude_session_id"] == "A"
