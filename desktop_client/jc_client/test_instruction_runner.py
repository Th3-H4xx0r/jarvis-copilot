"""Instructions from the phone for a Mac session that isn't in tmux: the Mac
continues that same conversation with `claude -p <text> --resume <id>` in the
session's own folder — the folder and id come from the hooks, never the phone."""
from jc_client.instruction_runner import InstructionRunner


class FakeProc:
    def __init__(self):
        self.done = False

    def poll(self):
        return 0 if self.done else None


def make(tmp_path, known=None):
    calls = []

    def popen(argv, cwd, env, stdout, stderr, stdin):
        calls.append({"argv": argv, "cwd": cwd})
        return FakeProc()

    sessions = known if known is not None else {"s1": "/w/app"}
    runner = InstructionRunner(popen=popen, find_claude=lambda: "/opt/bin/claude",
                               log_dir=str(tmp_path), session_cwd=sessions.get)
    return runner, calls


def test_runs_claude_resume_in_the_sessions_own_folder(tmp_path):
    runner, calls = make(tmp_path)
    ok, why = runner.run("s1", "/somewhere/else", "now run the tests")
    assert ok, why
    assert calls == [{"argv": ["/opt/bin/claude", "-p", "now run the tests", "--resume", "s1"],
                      "cwd": "/w/app"}]


def test_unknown_session_is_refused(tmp_path):
    runner, calls = make(tmp_path)
    ok, why = runner.run("nope", "/w/app", "rm -rf /")
    assert not ok and "unknown" in why and calls == []


def test_one_run_per_session_at_a_time(tmp_path):
    runner, calls = make(tmp_path)
    assert runner.run("s1", "", "one")[0]
    ok, why = runner.run("s1", "", "two")
    assert not ok and "already" in why
    runner._running["s1"].done = True
    assert runner.run("s1", "", "three")[0]
    assert len(calls) == 2


def test_missing_claude_is_reported(tmp_path):
    runner = InstructionRunner(popen=lambda *a, **k: None, find_claude=lambda: None,
                               log_dir=str(tmp_path), session_cwd={"s1": "/w"}.get)
    ok, why = runner.run("s1", "", "x")
    assert not ok and "claude" in why


def test_empty_text_is_refused(tmp_path):
    runner, calls = make(tmp_path)
    assert runner.run("s1", "", "   ")[0] is False and calls == []
