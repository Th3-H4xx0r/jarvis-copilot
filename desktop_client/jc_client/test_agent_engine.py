"""The shared agent engine: hook events in, per-session state out.

Runs unchanged in jc-client (the Mac island) and on the server (the phone), so
these tests are the single definition of what a state means."""
import pytest

from jc_client import agent_engine as ae


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def eng():
    clock = Clock()
    e = ae.Engine(clock=clock)
    e.clock = clock
    return e


def ev(name, sid="s1", cwd="/w/app", **kw):
    p = {"hook_event_name": name, "session_id": sid, "cwd": cwd}
    p.update(kw)
    return p


def one(e, sid="s1", host="mac", agent="claude"):
    return e.session(ae.session_key(host, agent, sid, "/w/app"))


def kinds(effects):
    return [x["kind"] for x in effects]


def test_full_turn_lifecycle(eng):
    eng.ingest("mac", "claude", ev("SessionStart", source="startup",
                                   term_program="Apple_Terminal", bundle_id="com.apple.Terminal"))
    s = one(eng)
    assert s["state"] == "idle" and s["project"] == "app"
    assert s["terminal"]["bundle_id"] == "com.apple.Terminal"

    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="run the tests"))
    s = one(eng)
    assert s["state"] == "thinking"
    assert s["turn"]["prompt"] == "run the tests"

    eng.ingest("mac", "claude", ev("PreToolUse", tool_name="Bash", tool_use_id="t1",
                                   tool_input={"command": "npm test -- --watch=false"}))
    s = one(eng)
    assert s["state"] == "working"
    assert s["step"].startswith("Bash: npm test")
    assert s["turn"]["actions"][0]["tool"] == "Bash"

    eng.ingest("mac", "claude", ev("PostToolUse", tool_name="Bash", tool_use_id="t1",
                                   tool_input={"command": "npm test -- --watch=false"},
                                   tool_response={"stdout": "ok\n" * 2000, "stderr": ""}))
    act = one(eng)["turn"]["actions"][0]
    assert act["output"].startswith("ok")
    assert len(act["output"]) <= ae.MAX_OUTPUT + 2
    assert act["failed"] is False

    effects = eng.ingest("mac", "claude", ev("Stop", last_assistant_message="All 42 tests pass."))
    s = one(eng)
    assert s["state"] == "finished"
    assert s["turn"]["final"] == "All 42 tests pass."
    assert s["turn"]["ended_at"] is not None
    assert {"notify", "turn_done", "state"} <= set(kinds(effects))
    assert [x for x in effects if x["kind"] == "notify"][0]["event"] == "stop"

    eng.clock.t += 4
    assert eng.sweep() == [] and one(eng)["state"] == "finished"
    eng.clock.t += 2
    effects = eng.sweep()
    assert one(eng)["state"] == "idle"
    assert kinds(effects) == ["state"]


def test_idle_prompt_notification_is_not_needs_you(eng):
    eng.ingest("mac", "claude", ev("SessionStart"))
    effects = eng.ingest("mac", "claude", ev("Notification", notification_type="idle_prompt",
                                             message="Claude is waiting for your input"))
    assert one(eng)["state"] == "idle"
    assert "notify" not in kinds(effects)


def test_permission_prompt_notification_without_pending_means_approval(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    effects = eng.ingest("mac", "claude", ev("Notification", notification_type="permission_prompt",
                                             message="Claude needs your permission to use Bash"))
    assert one(eng)["state"] == "approval"
    assert [x["event"] for x in effects if x["kind"] == "notify"] == ["notification"]


def test_permission_prompt_after_a_relayed_request_is_ignored(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    eng.ingest("mac", "claude", ev("PermissionRequest", tool_name="Bash", tool_use_id="t9",
                                   tool_input={"command": "rm -rf build"}), kind="permission")
    s = one(eng)
    assert s["state"] == "approval"
    assert s["pending"]["kind"] == "approval"
    assert s["pending"]["summary"] == "Bash: rm -rf build"
    effects = eng.ingest("mac", "claude", ev("Notification", notification_type="permission_prompt",
                                             message="needs permission"))
    assert "notify" not in kinds(effects)


def test_post_tool_use_settles_the_pending_approval(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    eng.ingest("mac", "claude", ev("PermissionRequest", tool_name="Bash", tool_use_id="t9",
                                   tool_input={"command": "ls"}), kind="permission")
    eng.ingest("mac", "claude", ev("PostToolUse", tool_name="Bash", tool_use_id="t9",
                                   tool_input={"command": "ls"}, tool_response={"stdout": "a"}))
    s = one(eng)
    assert s["pending"] is None and s["state"] == "working"


def test_elicitation_dialog_is_a_question(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    eng.ingest("mac", "claude", ev("Notification", notification_type="elicitation_dialog",
                                   message="An MCP server asks for input"))
    assert one(eng)["state"] == "question"


def test_ask_frame_sets_question_with_choices(eng):
    qs = [{"question": "Which db?", "options": [{"label": "A"}, {"label": "B"}]}]
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    effects = eng.ingest("mac", "claude", ev("PreToolUse", tool_name="AskUserQuestion",
                                             tool_use_id="q1", tool_input={"questions": qs}),
                         kind="ask")
    s = one(eng)
    assert s["state"] == "question"
    assert s["pending"]["questions"] == qs
    assert [x["event"] for x in effects if x["kind"] == "notify"] == ["question"]
    # the plain PreToolUse event for the same tool must not flip it back to working
    eng.ingest("mac", "claude", ev("PreToolUse", tool_name="AskUserQuestion", tool_use_id="q1",
                                   tool_input={"questions": qs}))
    assert one(eng)["state"] == "question"


def test_stop_failure_is_an_error(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    effects = eng.ingest("mac", "claude", ev("StopFailure", error="API Error: overloaded"))
    assert one(eng)["state"] == "error"
    assert [x["event"] for x in effects if x["kind"] == "notify"] == ["error"]


def test_rate_limit_notification(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    eng.ingest("mac", "claude", ev("Notification", message="Claude usage limit reached; rate limit resets 5pm"))
    assert one(eng)["state"] == "ratelimit"


def test_subagents_are_counted(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    eng.ingest("mac", "claude", ev("SubagentStart", agent_id="a1"))
    eng.ingest("mac", "claude", ev("SubagentStart", agent_id="a2"))
    eng.ingest("mac", "claude", ev("SubagentStop", agent_id="a1"))
    assert one(eng)["subagents"] == 1


def test_compaction_is_counted(eng):
    eng.ingest("mac", "claude", ev("PreCompact", trigger="auto"))
    eng.ingest("mac", "claude", ev("PostCompact", trigger="auto"))
    assert one(eng)["compactions"] == 1


def test_two_sessions_same_cwd(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", sid="a", prompt="one"))
    eng.ingest("mac", "claude", ev("UserPromptSubmit", sid="b", prompt="two"))
    eng.ingest("mac", "claude", ev("PreToolUse", sid="b", tool_name="Read", tool_use_id="r",
                                   tool_input={"file_path": "/w/app/x.py"}))
    eng.ingest("mac", "claude", ev("Stop", sid="a", last_assistant_message="done"))
    assert one(eng, "a")["state"] == "finished"
    assert one(eng, "b")["state"] == "working"
    eng.ingest("mac", "claude", ev("PermissionRequest", sid="b", tool_name="Bash", tool_use_id="z",
                                   tool_input={"command": "make"}), kind="permission")
    assert one(eng, "b")["state"] == "approval"
    assert one(eng, "a")["pending"] is None


def test_stuck_turn_stops_counting_as_working(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    eng.clock.t += ae.TURN_SILENCE + 1
    eng.sweep()
    assert one(eng)["state"] == "idle"


def test_silent_session_is_dropped(eng):
    eng.ingest("mac", "claude", ev("SessionStart"))
    eng.clock.t += ae.SESSION_SILENCE + 1
    effects = eng.sweep()
    assert one(eng) is None
    assert effects[0]["kind"] == "ended"


def test_session_end_removes_it(eng):
    eng.ingest("mac", "claude", ev("SessionStart"))
    effects = eng.ingest("mac", "claude", ev("SessionEnd", reason="exit"))
    assert one(eng) is None
    assert kinds(effects) == ["ended"]


def test_edit_diff_counts(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    inp = {"file_path": "/w/app/a.py", "old_string": "a = 1\nb = 2\n", "new_string": "a = 1\nb = 3\nc = 4\n"}
    eng.ingest("mac", "claude", ev("PreToolUse", tool_name="Edit", tool_use_id="e", tool_input=inp))
    eng.ingest("mac", "claude", ev("PostToolUse", tool_name="Edit", tool_use_id="e", tool_input=inp,
                                   tool_response={"filePath": "/w/app/a.py"}))
    f = one(eng)["turn"]["files"][0]
    assert (f["path"], f["added"], f["removed"], f["new"]) == ("/w/app/a.py", 2, 1, False)
    assert {"k": "-", "t": "b = 2"} in f["lines"] and {"k": "+", "t": "c = 4"} in f["lines"]
    assert one(eng)["turn"]["actions"][0]["file"] == 0


def test_multiedit_sums_and_write_is_new():
    d = ae.diff_from_tool("MultiEdit", {"file_path": "/x", "edits": [
        {"old_string": "a", "new_string": "b"}, {"old_string": "c", "new_string": "d\ne"}]})
    assert (d["added"], d["removed"]) == (3, 2)
    w = ae.diff_from_tool("Write", {"file_path": "/y", "content": "1\n2\n3\n"})
    assert (w["added"], w["removed"], w["new"]) == (3, 0, True)
    assert ae.diff_from_tool("Read", {"file_path": "/y"}) is None


def test_diff_caps():
    content = "\n".join("line %d %s" % (i, "x" * 600) for i in range(5000))
    d = ae.diff_from_tool("Write", {"file_path": "/big", "content": content}, budget=4000)
    assert len(d["lines"]) == ae.MAX_DIFF_LINES_PER_FILE
    assert d["truncated"] is True
    assert all(len(l["t"]) <= ae.MAX_LINE_CHARS + 1 for l in d["lines"])
    assert d["added"] == 5000
    small = ae.diff_from_tool("Write", {"file_path": "/big", "content": content}, budget=10)
    assert len(small["lines"]) == 10


def test_turn_line_budget_is_shared(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    content = "\n".join(str(i) for i in range(700))
    for n in range(8):
        inp = {"file_path": "/w/f%d" % n, "content": content}
        eng.ingest("mac", "claude", ev("PostToolUse", tool_name="Write", tool_use_id="w%d" % n,
                                       tool_input=inp, tool_response={}))
    total = sum(len(f["lines"]) for f in one(eng)["turn"]["files"])
    assert total <= ae.MAX_DIFF_LINES_PER_TURN


def test_steps_are_capped(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    for i in range(60):
        eng.ingest("mac", "claude", ev("PreToolUse", tool_name="Read", tool_use_id="r%d" % i,
                                       tool_input={"file_path": "/w/f%d.py" % i}))
    s = one(eng)
    assert len(s["steps"]) == ae.MAX_STEPS
    assert s["steps"][-1]["t"] == "Read f59.py"


def test_step_labels():
    assert ae.step_label("Bash", {"command": "git status\nls"}) == "Bash: git status"
    assert ae.step_label("Read", {"file_path": "/a/b/c.swift"}) == "Read c.swift"
    assert ae.step_label("Grep", {"pattern": "TODO"}) == "Search TODO"
    assert ae.step_label("WebFetch", {"url": "https://docs.swift.org/x"}) == "Fetch docs.swift.org"
    assert ae.step_label("Task", {"description": "map the code"}) == "Agent: map the code"
    assert ae.step_label("mcp__github__create_pr", {}) == "github: create_pr"


def test_anonymous_session_keys_on_cwd(eng):
    eng.ingest("mac", "gemini", {"hook_event_name": "UserPromptSubmit", "cwd": "/w/app", "prompt": "hi"})
    key = ae.session_key("mac", "gemini", "", "/w/app")
    assert eng.session(key)["state"] == "thinking"


def test_fingerprint_is_stable_and_specific():
    a = ae.fingerprint("s", "t1", "Bash", {"command": "ls", "x": 1})
    b = ae.fingerprint("s", "t1", "Bash", {"x": 1, "command": "ls"})
    c = ae.fingerprint("s", "t2", "Bash", {"command": "ls", "x": 1})
    assert a == b and a != c and len(a) == 32


def test_sessions_sorted_by_urgency(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", sid="w", prompt="x"))
    eng.ingest("mac", "claude", ev("SessionStart", sid="i"))
    eng.ingest("mac", "claude", ev("UserPromptSubmit", sid="q", prompt="x"))
    eng.ingest("mac", "claude", ev("PermissionRequest", sid="q", tool_name="Bash", tool_use_id="1",
                                   tool_input={"command": "ls"}), kind="permission")
    assert [s["session_id"] for s in eng.sessions()] == ["q", "w", "i"]


def test_snapshot_roundtrip(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="keep me"))
    snap = eng.snapshot()
    other = ae.Engine(clock=eng.clock)
    other.restore(snap)
    assert other.session(ae.session_key("mac", "claude", "s1", "/w/app"))["turn"]["prompt"] == "keep me"


def test_drop_removes_one_session(eng):
    eng.ingest("mac", "claude", ev("SessionStart", sid="a"))
    eng.ingest("mac", "claude", ev("SessionStart", sid="b"))
    gone = eng.drop(ae.session_key("mac", "claude", "a", "/w/app"))
    assert gone["session_id"] == "a"
    assert [s["session_id"] for s in eng.sessions()] == ["b"]
    assert eng.drop("nope") is None


def test_unknown_event_is_harmless(eng):
    eng.ingest("mac", "claude", ev("UserPromptSubmit", prompt="x"))
    assert isinstance(eng.ingest("mac", "claude", ev("SomethingNew")), list)
    assert one(eng)["state"] == "thinking"
    assert eng.ingest("mac", "claude", {"cwd": "/w"}) == []
    assert eng.ingest("mac", "claude", "not a dict") == []
