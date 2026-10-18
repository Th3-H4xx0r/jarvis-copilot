"""The merged Agents list: one row per conversation, Mac-asleep card, hand-offs."""
from __future__ import annotations

import base64
import json
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
from agent import transcript_mirror as tm  # noqa: E402
from api import agents_core  # noqa: E402
from api.coding_routes import handle_coding_request  # noqa: E402


class FakeClaude:
    def __init__(self):
        self.started, self.sent, self.stopped = [], [], []

    def ensure_trusted(self, cwd):
        pass

    def start(self, cwd, **kw):
        self.started.append((cwd, kw))
        return "bg000001"

    def send(self, bg, text, timeout=8.0):
        self.sent.append((bg, text))

    def stop(self, bg):
        self.stopped.append(bg)

    def roster(self):
        return []

    def job_for(self, session_id):
        return None

    def job_session(self, bg_id):
        return None


class FakeCodex:
    def available(self):
        return False, "Codex isn't installed on the server"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("JC_CODING_PROJECTS_ROOT", str(tmp_path / "cp"))
    store = CodingSessionStore(str(tmp_path / "c.db"))
    frames, pushes, syncs = [], [], []
    core = agents_core.AgentsCore(
        store, send_frame=lambda d, f: frames.append((d, f)) or True,
        device_name=lambda d: "MacBook",
        alert_phones=lambda title, body, **kw: pushes.append((title, body, kw)) or 1,
        claude=FakeClaude(), codex=FakeCodex(), project_synced=lambda row: True,
        start_sync=lambda device, local, server: syncs.append((device, local, server)))
    agents_core.set_core(core)
    tr = AgentTracker(store, observer=core.on_hook)
    set_tracker(tr)
    yield {"store": store, "core": core, "tr": tr, "frames": frames, "pushes": pushes,
           "syncs": syncs, "tmp": tmp_path}
    set_tracker(None)
    agents_core.set_core(None)


def ev(name, sid="s1", cwd="/Users/p/app", **kw):
    p = {"hook_event_name": name, "session_id": sid, "cwd": cwd}
    p.update(kw)
    return p


def call(method, path, body=None):
    return handle_coding_request(method, path, body, manager=None, manager_for_host=None)


def _three(env):
    tr = env["tr"]
    env["core"].on_hello("d1", {})
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="s1", prompt="Fix the router"))
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="s2", prompt="Write docs\nmore"))
    tr.ingest("d1", "permission", "claude", ev("PermissionRequest", sid="s3", cwd="/Users/p/other",
                                               tool_name="Bash", tool_input={"command": "git push"}))


def _ship(env, sid, lines):
    data = ("\n".join(json.dumps(x) for x in lines) + "\n").encode()
    env["core"].on_chunk("d1", {"ckey": f"claude|{sid}", "agent": "claude", "session_id": sid,
                                "cwd": "/Users/p/app", "offset": 0,
                                "data_b64": base64.b64encode(data).decode()})


def test_list_groups_by_project_and_needs_you_flat(env):
    _three(env)
    status, body = call("GET", "/agents/list")
    assert status == 200
    assert [c["ckey"] for c in body["needs_you"]] == ["claude|s3"]
    assert body["needs_you"][0]["pending"]["tool"] == "Bash"
    (proj,) = body["projects"]
    assert proj["name"] == "app"
    assert sorted(c["ckey"] for c in proj["sessions"]) == ["claude|s1", "claude|s2"]
    titles = {c["ckey"]: c["title"] for c in proj["sessions"]}
    assert titles["claude|s2"] == "Write docs"
    s1 = next(c for c in proj["sessions"] if c["ckey"] == "claude|s1")
    assert s1["owner"] == "d1" and s1["owner_name"] == "MacBook" and s1["status"] == "live"
    assert s1["can_continue_server"] is False and body["card"] is None


def test_card_present_after_sleep_frame(env):
    _three(env)
    env["core"].on_sleeping("d1", {"entries": []})
    _, body = call("GET", "/agents/list")
    card = body["card"]
    assert card["kind"] == "sleep" and card["device_name"] == "MacBook"
    assert {s["ckey"] for s in card["sessions"]} == {"claude|s1", "claude|s2", "claude|s3"}
    assert all(s["title"] for s in card["sessions"])
    (title, text, kw), = env["pushes"]
    assert title == "MacBook went to sleep" and text == "3 sessions paused"
    assert kw["category"] == "MAC_SLEPT"


def test_send_to_offline_owner_409(env):
    _three(env)
    env["core"].on_sleeping("d1", {"entries": []})
    status, body = call("POST", "/agents/send", {"ckey": "claude|s1", "text": "hi"})
    assert status == 409 and body["delivery"]["state"] == "failed"
    assert body["delivery"]["reason"] == "owner_offline"


def test_continue_endpoint_calls_handoff_per_ckey(env):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hi"}}])
    env["core"].on_sleeping("d1", {"entries": []})
    status, body = call("POST", "/agents/continue",
                        {"ckeys": ["claude|s1", "claude|s2"], "to": "server"})
    assert status == 200
    assert body["results"]["claude|s1"]["ok"] is True
    assert body["results"]["claude|s2"]["reason"] == "no_transcript"
    _, lst = call("GET", "/agents/list")
    assert {s["ckey"] for s in lst["card"]["sessions"]} == {"claude|s2", "claude|s3"}


def test_messages_reads_server_copy(env):
    _three(env)
    _ship(env, "s1", [
        {"type": "user", "uuid": "u1", "timestamp": "2026-10-17T10:00:00Z",
         "message": {"role": "user", "content": "Fix the router"}},
        {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-17T10:00:05Z",
         "message": {"role": "assistant", "content": [{"type": "text", "text": "Done."}]}}])
    status, body = call("GET", "/agents/messages?ckey=claude%7Cs1")
    assert status == 200 and body["total"] == 2
    assert [m["role"] for m in body["messages"]] == ["user", "assistant"]


def _part(env, sid, data, offset, of):
    env["core"].on_chunk("d1", {"ckey": f"claude|{sid}", "agent": "claude", "session_id": sid,
                                "cwd": "/Users/p/app", "offset": offset, "size": of,
                                "data_b64": base64.b64encode(data).decode()})


def test_a_long_chat_still_on_its_way_says_so_then_opens_on_its_end(env, monkeypatch):
    # The server only has a long chat's oldest part until its copy lands:
    # showing that part made the phone open on the start and fill downward.
    monkeypatch.setattr(agents_core, "_SYNC_LAG", 100)
    _three(env)
    data = "".join(json.dumps({"type": "user", "uuid": f"u{n}", "message": {
        "role": "user", "content": f"step {n} " + "x" * 40}}) + "\n" for n in range(8)).encode()
    _part(env, "s1", data[:150], 0, len(data))
    status, body = call("GET", "/agents/messages?ckey=claude%7Cs1&limit=40")
    assert status == 200 and body["messages"] == []
    assert body["syncing"] == {"have": 150, "of": len(data)}
    _part(env, "s1", data[150:], 150, len(data))
    status, body = call("GET", "/agents/messages?ckey=claude%7Cs1&limit=40")
    assert "syncing" not in body and body["total"] == 8
    assert body["messages"][-1]["text"].startswith("step 7")


def test_a_long_copy_pushes_the_list_each_tenth_not_each_part(env, monkeypatch):
    monkeypatch.setattr(agents_core, "_SYNC_LAG", 10)
    _three(env)
    pushes = []
    env["core"]._publish_cb = lambda topic, payload: pushes.append(topic)
    data = b'{"type":"user"}\n' * 100
    for off in range(0, len(data), 16):
        _part(env, "s1", data[off:off + 16], off, len(data))
    assert len(pushes) == 11   # each tenth of the way, then once it's whole
    pushes.clear()
    more = b'{"type":"user"}\n'
    _part(env, "s1", more, len(data), len(data) + len(more))
    assert len(pushes) == 1, "a live chat's new lines still push at once"


def test_chunk_at_wrong_offset_asks_to_resend(env):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    env["frames"].clear()
    env["core"].on_chunk("d1", {"ckey": "claude|s1", "agent": "claude", "session_id": "s1",
                                "cwd": "/Users/p/app", "offset": 0, "data_b64": "eA=="})
    (dev, frame), = env["frames"]
    assert frame["type"] == "agent_transcript_ack" and frame["ok"] is False and frame["size"] > 0


def test_hook_from_old_owner_after_move_does_not_steal_owner(env):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    env["core"].on_sleeping("d1", {"entries": []})
    call("POST", "/agents/continue", {"ckeys": ["claude|s1"], "to": "server"})
    env["core"].on_hello("d1", {})
    env["tr"].ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="s1", prompt="stale"))
    assert env["core"].conv.get("claude|s1")["owner"] == "server"


def test_prompt_hook_marks_delivery(env):
    _three(env)
    status, body = call("POST", "/agents/send", {"ckey": "claude|s1", "text": "Run the tests"})
    assert status == 200 and body["delivery"]["state"] == "sent"
    (dev, frame) = env["frames"][-1]
    assert dev == "d1" and frame["type"] == "agent_instruction"
    env["tr"].ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="s1", prompt="Run the tests"))
    assert env["core"].deliveries.get(body["delivery"]["id"])["state"] == "delivered"


def test_hello_triggers_roster_request_and_merge_back(env):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    env["core"].on_sleeping("d1", {"entries": []})
    call("POST", "/agents/continue", {"ckeys": ["claude|s1"], "to": "server"})
    from agent import transcript_mirror as tm
    row = env["core"].conv.get("claude|s1")
    tm.append_chunk(row, tm.size(row), b'{"type":"user","uuid":"u2"}\n')   # a new server turn
    env["frames"].clear()
    env["core"].on_hello("d1", {})
    types = [f["type"] for _, f in env["frames"]]
    assert "agent_roster_request" in types and "agent_moved" in types
    assert "agent_transcript_sync" in types


def test_roster_from_mac_adds_project(env):
    env["core"].on_hello("d1", {})
    env["core"].on_roster("d1", {"entries": [{"agent": "claude", "session_id": "r1", "pid": 9,
                                              "kind": "interactive", "cwd": "/Users/p/app",
                                              "name": "From roster"}]})
    _, body = call("GET", "/agents/list")
    (proj,) = body["projects"]
    assert proj["name"] == "app" and proj["sessions"][0]["title"] == "From roster"


def test_island_bring_back_runs_continue_on_mac(env):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    env["core"].on_sleeping("d1", {"entries": []})
    call("POST", "/agents/continue", {"ckeys": ["claude|s1"], "to": "server"})
    env["core"].on_hello("d1", {})
    env["frames"].clear()
    env["core"].on_continue_mac("d1", {"ckey": "claude|s1"})
    assert env["core"].conv.get("claude|s1")["status"] == "moving"
    assert any(f["type"] == "agent_transcript_sync" and f.get("then") == "resume_local"
               for _, f in env["frames"])


def test_new_mac_project_turns_sync_on(env):
    _three(env)
    pid = env["core"].conv.get("claude|s1")["project_id"]
    assert env["store"].get_project(pid)["sync_enabled"]
    assert ("d1", "/Users/p/app", str(env["tmp"] / "cp" / "app")) in env["syncs"]
    assert len([s for s in env["syncs"] if s[1] == "/Users/p/app"]) == 1


def test_switched_off_project_is_not_synced(env):
    env["core"].on_hello("d1", {})
    pid = env["store"].get_or_create_project_for_path(repo_path="/Users/p/app", host="desktop",
                                                      device_id="d1")
    env["core"].set_project_sync(pid, False)
    env["tr"].ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="s1", prompt="x"))
    assert env["syncs"] == [] and not env["store"].get_project(pid)["sync_enabled"]


def test_project_sync_switch_route(env):
    _three(env)
    pid = env["core"].conv.get("claude|s1")["project_id"]
    status, body = call("POST", "/agents/project/sync", {"project_id": pid, "on": False})
    assert status == 200 and not env["store"].get_project(pid)["sync_enabled"]
    assert pid in env["store"].get_setting("sync_off_projects", [])


def test_list_carries_recent_deliveries_and_project_sync(env):
    _three(env)
    _, sent = call("POST", "/agents/send", {"ckey": "claude|s1", "text": "Run the tests"})
    env["core"].on_delivery("d1", {"delivery_id": sent["delivery"]["id"], "state": "queued"})
    _, body = call("GET", "/agents/list")
    (proj,) = body["projects"]
    assert proj["sync_enabled"] is True
    s1 = next(c for c in proj["sessions"] if c["ckey"] == "claude|s1")
    assert s1["deliveries"][0] == {"id": sent["delivery"]["id"], "state": "queued", "reason": None}


def test_messages_full_tool_output_on_request(env, monkeypatch):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    seen = {}
    import agent.coding_transcript_read as ctr
    real = ctr.slice_messages
    monkeypatch.setattr(ctr, "slice_messages",
                        lambda *a, **kw: seen.update(lite=kw.get("lite")) or real(*a, **kw))
    call("GET", "/agents/messages?ckey=claude%7Cs1&lite=0")
    assert seen["lite"] is False
    call("GET", "/agents/messages?ckey=claude%7Cs1")
    assert seen["lite"] is True


def test_launch_on_the_mac_keeps_the_macs_own_path(env):
    """The Mac's folder typeahead answers with ~/... paths; expanding them here
    would hand the Mac the server's home."""
    env["core"].on_hello("d1", {})
    env["frames"].clear()
    status, _ = call("POST", "/agents/launch", {"where": "d1", "cwd": "~/code/app"})
    assert status == 200
    (dev, frame), = [(d, f) for d, f in env["frames"] if f["type"] == "agent_launch"]
    assert dev == "d1" and frame["cwd"] == "~/code/app"


def test_chunk_paths_cannot_escape_the_transcript_dirs(env):
    """A device's ckey / codex_rel name a file under ~/.claude or ~/.codex only."""
    tmp = env["tmp"]
    env["core"].on_hello("d1", {})
    data = base64.b64encode(b"pwned\n").decode()
    env["core"].on_chunk("d1", {"ckey": "codex|c1", "agent": "codex", "session_id": "c1",
                                "cwd": "/Users/p/app", "offset": 0, "data_b64": data,
                                "codex_rel": "../../evil.sh"})
    env["core"].on_chunk("d1", {"ckey": "claude|../../../../evil2", "agent": "claude",
                                "cwd": "/Users/p/app", "offset": 0, "data_b64": data})
    assert not (tmp / "evil.sh").exists() and not (tmp.parent / "evil.sh").exists()
    assert not list(tmp.rglob("evil2*")) and not list(tmp.parent.glob("evil2*"))


def test_a_moved_sessions_state_comes_from_where_it_runs(env):
    """The Mac's stale copy of a moved session can still be tracked there; the
    row shows the server run's state, not the stale one's."""
    tr = env["tr"]
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    env["core"].on_sleeping("d1", {"entries": []})
    call("POST", "/agents/continue", {"ckeys": ["claude|s1"], "to": "server"})
    tr.ingest(None, "permission", "claude", ev("PermissionRequest", sid="s1", cwd="/srv/app",
                                               tool_name="Bash", tool_input={"command": "ls"}))
    tr.ingest("d1", "event", "claude", ev("UserPromptSubmit", sid="s1", prompt="stale"))
    _, body = call("GET", "/agents/list")
    row = next(c for c in body["needs_you"] if c["ckey"] == "claude|s1")
    assert row["owner"] == "server" and row["state"] == "approval"


def test_message_cache_keeps_only_recent_sessions(env):
    for i in range(40):
        _ship(env, f"m{i}", [{"type": "user", "uuid": f"u{i}",
                              "message": {"role": "user", "content": "x"}}])
        env["core"].messages(f"claude|m{i}")
    assert len(env["core"]._msg_cache) <= 16


def _moved_then_stopped(env):
    _three(env)
    _ship(env, "s1", [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "x"}}])
    env["core"].on_sleeping("d1", {"entries": []})
    call("POST", "/agents/continue", {"ckeys": ["claude|s1"], "to": "server"})
    env["core"].on_hello("d1", {})
    call("POST", "/agents/stop", {"ckey": "claude|s1"})
    assert env["core"].conv.get("claude|s1")["status"] == "ended"


def test_the_macs_stale_copy_is_not_adopted_after_the_server_run_ends(env):
    """The stale Mac process of a moved session is still alive (blocked), so
    `claude agents` on the Mac lists it. Once the server run is stopped, that
    must not make it the conversation again: the gate would then let it take
    prompts from its out-of-date memory and fork the transcript."""
    _moved_then_stopped(env)
    env["core"].on_roster("d1", {"entries": [{"agent": "claude", "session_id": "s1", "pid": 9,
                                              "kind": "interactive", "cwd": "/Users/p/app"}],
                                 "agents": ["claude", "codex"]})
    env["tr"].ingest("d1", "event", "claude", ev("Notification", sid="s1"))
    row = env["core"].conv.get("claude|s1")
    assert row["owner"] == "server" and row["status"] == "ended"
    env["frames"].clear()
    env["core"].on_hello("d1", {})
    moved = [f for _, f in env["frames"] if f["type"] == "agent_moved"]
    assert "claude|s1" in moved[-1]["ckeys"]


def test_a_session_resumed_by_hand_is_live_without_its_old_process(env):
    """Ended, then resumed by hand in a new process (`claude --resume`): its
    SessionStart makes it live again, and the old run's pid or --bg id is
    dropped until the roster names the new process: a message typed meanwhile
    must not go looking for the dead one."""
    core, tr = env["core"], env["tr"]
    core.on_hello("d1", {})
    for old in ({"pid": 1215, "kind": "interactive"}, {"bg_id": "bg1", "kind": "background"}):
        core.on_roster("d1", {"entries": [dict(old, agent="claude", session_id="s1",
                                               cwd="/Users/p/app")],
                              "agents": ["claude", "codex"]})
        core.on_roster("d1", {"entries": [], "agents": ["claude", "codex"]})
        assert core.conv.get("claude|s1")["status"] == "ended"
        tr.ingest("d1", "event", "claude", ev("SessionStart", source="resume",
                                              term_program="vscode"))
        row = core.conv.get("claude|s1")
        assert row["status"] == "live", old
        assert row["run"].get("kind") == "interactive" and "pid" not in row["run"] \
            and "bg_id" not in row["run"], row["run"]
        assert row["run"]["terminal"]["term_program"] == "vscode"
        tr.ingest("d1", "event", "claude", ev("SessionEnd"))


def test_resuming_a_moved_session_on_the_mac_merges_first(env):
    """Resume on Mac of a session that ran on the server: the server's turns are
    merged into the Mac's copy before it reopens (the Continue-on-Mac path)."""
    _moved_then_stopped(env)
    env["frames"].clear()
    status, _ = call("POST", "/agents/resume", {"ckey": "claude|s1", "where": "mac"})
    assert status == 200
    assert any(f["type"] == "agent_transcript_sync" and f.get("then") == "resume_local"
               for _, f in env["frames"])
    assert not any(f["type"] == "agent_resume_local" for _, f in env["frames"])


class FakeCodexServer:
    def __init__(self):
        self.answered = []

    def available(self):
        return True, ""

    def answer_approval(self, approval_id, decision):
        self.answered.append((approval_id, decision))
        return True


def test_server_codex_approval_reaches_needs_you_and_is_answered(env):
    from api import agent_hooks  # noqa: F401  (installs the decision router)
    from api import coding_permission as cp
    cp._reset_for_tests()
    codex = FakeCodexServer()
    env["core"].codex = env["core"].handoff.codex = codex
    env["core"].conv.upsert("codex|c1", agent="codex", session_id="c1", owner="server",
                            status="live", cwd="/srv/app", title="Port the parser",
                            run={"kind": "headless", "handle": "c1"})
    env["core"].on_codex_event("approval", {"id": "a1", "handle": "c1", "kind": "command",
                                            "title": "Run ls -la", "command": "ls -la",
                                            "cwd": "/srv/app"})
    _, body = call("GET", "/agents/list")
    (c,) = body["needs_you"]
    assert c["ckey"] == "codex|c1" and c["pending"]["summary"] == "Run ls -la"
    (req,) = [r for r in cp.list_pending() if r.get("fingerprint") == "codex:a1"]
    status, _ = call("POST", "/permission/verdict", {"request_id": req["request_id"],
                                                     "decision": "allow"})
    assert status == 200 and codex.answered == [("a1", "allow")]
    env["core"].on_codex_event("approval_resolved", {"id": "a1", "handle": "c1"})
    _, body = call("GET", "/agents/list")
    assert body["needs_you"] == []


def test_waiting_session_cannot_send(env):
    _three(env)
    _, body = call("GET", "/agents/list")
    (c,) = body["needs_you"]
    assert c["can_send"] is False


def test_offline_after_grace_pushes_the_list(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    store = CodingSessionStore(str(tmp_path / "c2.db"))
    t = {"now": 1000.0}
    pushed = []
    core = agents_core.AgentsCore(store, send_frame=lambda d, f: True, device_name=lambda d: "Mac",
                                  claude=FakeClaude(), codex=FakeCodex(), clock=lambda: t["now"],
                                  publish=lambda topic, data: pushed.append(data), tracker=lambda: None,
                                  start_sync=lambda *a: None)
    core.conv.upsert("claude|z", agent="claude", session_id="z", owner="d9", status="live")
    core.on_disconnect("d9")
    pushed.clear()
    t["now"] += 61
    core.tick()
    assert pushed and pushed[-1]["card"]["kind"] == "offline"


def test_titles_prefer_the_ai_title_and_sessions_sort_by_activity(env):
    env["core"].on_hello("d1", {})
    env["core"].on_roster("d1", {"entries": [
        {"agent": "claude", "session_id": "old", "pid": 1, "kind": "interactive", "cwd": "/Users/p/app",
         "name": "app-a1", "title": "Older work", "last_active_at": 1000.0},
        {"agent": "claude", "session_id": "new", "pid": 2, "kind": "interactive", "cwd": "/Users/p/app",
         "name": "app-b2", "title": "Newest work", "last_active_at": 5000.0},
        {"agent": "claude", "session_id": "plain", "pid": 3, "kind": "interactive", "cwd": "/Users/p/app",
         "name": "app-c3", "last_active_at": 3000.0}]})
    _, body = call("GET", "/agents/list")
    (proj,) = body["projects"]
    assert [c["title"] for c in proj["sessions"]] == ["Newest work", "app-c3", "Older work"]
    assert proj["sessions"][0]["last_event_at"] == 5000.0


def test_a_session_whose_mac_just_dropped_offers_the_server(env):
    env["core"].on_hello("d1", {})
    env["core"].on_roster("d1", {"entries": [
        {"agent": "claude", "session_id": "gone", "pid": 1, "kind": "interactive", "cwd": "/Users/p/app",
         "terminal": {"term_program": "vscode"}}]})
    env["core"].on_disconnect("d1")
    _, body = call("GET", "/agents/list")
    (c,) = [s for p in body["projects"] for s in p["sessions"] if s["session_id"] == "gone"]
    assert c["status"] == "offline" and c["can_send"] is False and c["can_continue_server"] is True


def test_server_sessions_are_watched_between_hooks(tmp_path, monkeypatch):
    """A session running on the server shows working while Claude's job file
    says so (sessions started before they had hooks), and each new write to its
    transcript reaches open screens without waiting for a hook."""
    monkeypatch.setenv("HOME", str(tmp_path))
    store = CodingSessionStore(str(tmp_path / "w.db"))
    t = {"now": 1000.0}
    pushed = []
    job = {"state": "working"}

    class Claude(FakeClaude):
        def job_state(self, bg):
            return dict(job) if bg == "bg000001" else {}

        def roster(self):
            return [{"agent": "claude", "session_id": "z", "kind": "background", "bg_id": "bg000001",
                     "cwd": str(tmp_path / "app"), "status": job["state"]}]

    core = agents_core.AgentsCore(store, send_frame=lambda d, f: True, device_name=lambda d: "Mac",
                                  claude=Claude(), codex=FakeCodex(), clock=lambda: t["now"],
                                  publish=lambda topic, data: pushed.append(data), tracker=lambda: None,
                                  start_sync=lambda *a: None)
    core.conv.upsert("claude|z", agent="claude", session_id="z", owner="server", status="live",
                     state="idle", cwd=str(tmp_path / "app"), run={"kind": "background", "bg_id": "bg000001"})
    row = core.conv.get("claude|z")
    tm.append_chunk(row, 0, b'{"uuid":"a"}\n')

    def tick():
        t["now"] += 6
        core.tick()

    tick()
    assert core.conv.get("claude|z")["state"] == "working" and pushed
    pushed.clear()
    tick()
    assert pushed == [], "nothing new, nothing pushed"
    tm.append_chunk(row, tm.size(row), b'{"uuid":"b"}\n')
    import os
    os.utime(tm.path_for(row), (t["now"] + 1, t["now"] + 1))
    tick()
    assert pushed, "a transcript write is pushed"
    job["state"] = "done"
    pushed.clear()
    tick()
    assert core.conv.get("claude|z")["state"] == "idle" and pushed
