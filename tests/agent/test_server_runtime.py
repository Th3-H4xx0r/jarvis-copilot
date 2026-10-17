"""Claude sessions on the server run as Claude's own background sessions."""
import json
import subprocess

import pytest

from agent.server_runtime import ClaudeRuntime, DeliveryError

AGENTS_JSON = json.dumps([
    {"id": "745e113e", "cwd": "/srv/app", "kind": "background", "startedAt": 1,
     "sessionId": "745e113e-a511", "name": "ready reply", "status": "idle", "state": "done"},
    {"pid": 4707, "cwd": "/srv/other", "kind": "interactive", "startedAt": 2,
     "sessionId": "3fcbe39e-1db7", "name": "other", "status": "busy"},
])


class Run:
    def __init__(self, stdout="", returncode=0):
        self.calls, self.stdout, self.returncode = [], stdout, returncode

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        out = kw.get("stdout")
        if hasattr(out, "write"):
            out.write(self.stdout)
            out.flush()
            return subprocess.CompletedProcess(argv, self.returncode, None, None)
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, "")


class FakePty:
    def __init__(self, output=b"\x1b[2J welcome", fail_open=False):
        self.writes, self.closed, self.output, self.fail_open = [], False, output, fail_open

    def read_some(self, timeout):
        return b"" if self.fail_open else self.output

    def write(self, data):
        self.writes.append(data)

    def close(self):
        self.closed = True


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-should-not-leak")
    return tmp_path


def test_start_argv_no_shell_and_scrubbed_env(home):
    run = Run(stdout="backgrounded · 1a2b3c4d\n  claude agents  list sessions\n")
    rt = ClaudeRuntime(run=run, pty_factory=None)
    bg = rt.start("/srv/app", prompt="hi", model="claude-sonnet-5-5")
    assert bg == "1a2b3c4d"
    argv, kw = run.calls[-1]
    assert argv[:2] == ["claude", "--bg"] and "--model" in argv and argv[-1] == "hi"
    assert kw.get("shell") in (None, False) and kw["cwd"] == "/srv/app"
    assert "ANTHROPIC_API_KEY" not in kw["env"]


def test_start_does_not_pipe_stdout(home):
    """`claude --bg` leaves a daemon holding whatever stdout it was given; a pipe
    would never reach EOF and the call would hang (seen live, 2026-10-17)."""
    run = Run(stdout="backgrounded · 1a2b3c4d\n")
    ClaudeRuntime(run=run).start("/srv/app")
    _argv, kw = run.calls[-1]
    assert not kw.get("capture_output") and hasattr(kw.get("stdout"), "write")


def test_model_outside_allowlist_is_dropped(home):
    run = Run(stdout="backgrounded · 1a2b3c4d\n")
    ClaudeRuntime(run=run).start("/srv/app", model="gpt-5; rm -rf /")
    assert "--model" not in run.calls[-1][0]


def test_resume_passes_session_id(home):
    run = Run(stdout="backgrounded · 745e113e\n")
    ClaudeRuntime(run=run).start("/srv/app", resume_session_id="745e113e-a511", model="claude-opus-5-5")
    argv = run.calls[-1][0]
    assert argv[argv.index("--resume") + 1] == "745e113e-a511" and "--model" in argv


def test_resume_bg_origin_passes_no_flags(home):
    run = Run(stdout="backgrounded · 745e113e\n")
    ClaudeRuntime(run=run).start("/srv/app", resume_session_id="745e113e-a511", bg_origin=True,
                                 model="claude-opus-5-5", permission_mode="acceptEdits")
    assert run.calls[-1][0] == ["claude", "--bg", "--resume", "745e113e-a511"]


def test_bypass_permissions_as_root_sets_sandbox(home, monkeypatch):
    monkeypatch.setattr("os.geteuid", lambda: 0)
    run = Run(stdout="backgrounded · 1a2b3c4d\n")
    ClaudeRuntime(run=run).start("/srv/app", permission_mode="bypassPermissions")
    argv, kw = run.calls[-1]
    assert "--permission-mode" in argv and kw["env"].get("IS_SANDBOX") == "1"


def test_start_failure_raises(home):
    run = Run(stdout="Workspace not trusted.", returncode=1)
    with pytest.raises(RuntimeError):
        ClaudeRuntime(run=run).start("/srv/app")


def test_send_uses_bracketed_paste_then_cr(home):
    fake = FakePty()
    rt = ClaudeRuntime(run=Run(), pty_factory=lambda argv: fake, settle=0)
    rt.send("745e113e", "line one\nline two")
    assert fake.writes[0] == b"\x1b[200~line one\nline two\x1b[201~"
    assert fake.writes[-1] == b"\r" and fake.closed


def test_send_raises_when_session_never_opens(home):
    fake = FakePty(fail_open=True)
    rt = ClaudeRuntime(run=Run(), pty_factory=lambda argv: fake, settle=0)
    with pytest.raises(DeliveryError):
        rt.send("745e113e", "hi", timeout=0.05)
    assert fake.closed and fake.writes == []


def test_roster_parses_agents_json(home):
    rt = ClaudeRuntime(run=Run(stdout=AGENTS_JSON))
    entries = rt.roster()
    bg = next(e for e in entries if e["session_id"] == "745e113e-a511")
    assert bg == {"agent": "claude", "session_id": "745e113e-a511", "kind": "background",
                  "bg_id": "745e113e", "cwd": "/srv/app", "name": "ready reply",
                  "status": "idle", "pid": None}
    inter = next(e for e in entries if e["session_id"] == "3fcbe39e-1db7")
    assert inter["pid"] == 4707 and inter["kind"] == "interactive" and inter["bg_id"] is None


def test_roster_failure_raises_instead_of_listing_nothing(home):
    """An empty list means "every server session ended": a failed or garbled
    `claude agents` (timeout, update in progress, a notice on stdout) must not
    say that."""
    with pytest.raises(RuntimeError):
        ClaudeRuntime(run=Run(stdout="nope")).roster()
    with pytest.raises(RuntimeError):
        ClaudeRuntime(run=Run(stdout="[]", returncode=1)).roster()
    assert ClaudeRuntime(run=Run(stdout="[]")).roster() == []


def test_ensure_trusted_preserves_other_keys(home):
    cfg = home / ".claude.json"
    cfg.write_text(json.dumps({"numStartups": 7, "projects": {"/x": {"allowedTools": ["a"]}}}))
    ClaudeRuntime(run=Run()).ensure_trusted(str(home))
    data = json.loads(cfg.read_text())
    assert data["numStartups"] == 7 and data["projects"]["/x"] == {"allowedTools": ["a"]}
    import os
    assert data["projects"][os.path.realpath(str(home))]["hasTrustDialogAccepted"] is True


def test_attach_argv():
    assert ClaudeRuntime(run=Run()).attach_argv("745e113e") == ["claude", "attach", "745e113e"]


def test_send_now_uses_ctrl_enter(home):
    fake = FakePty()
    rt = ClaudeRuntime(run=Run(), pty_factory=lambda argv: fake, settle=0)
    rt.send("745e113e", "go", now=True)
    assert fake.writes[-1] == b"\x1b[13;5u"


def test_send_while_working_holds_the_attach_until_idle(home):
    """Claude keeps a message typed while it works in the attach client's own
    queue: closing that client at once would lose it."""
    import time
    fake = FakePty()
    idle = {"now": False}
    rt = ClaudeRuntime(run=Run(), pty_factory=lambda argv: fake, settle=0)
    rt.send("745e113e", "next", hold_until=lambda: idle["now"], hold_poll=0.05)
    time.sleep(0.15)
    assert fake.closed is False
    idle["now"] = True
    time.sleep(0.3)
    assert fake.closed is True


def test_trusting_folders_at_once_keeps_every_one(home, monkeypatch):
    """Two Continues landing together each read ~/.claude.json, add their
    folder and write it back: without a lock the second write drops the first."""
    import json as _json
    import threading
    import time
    import agent.server_runtime as sr
    real_dump = _json.dump

    def slow_dump(*a, **kw):
        time.sleep(0.05)
        return real_dump(*a, **kw)
    monkeypatch.setattr(sr.json, "dump", slow_dump)
    rt = ClaudeRuntime(run=Run())
    dirs = []
    for n in range(4):
        d = home / f"p{n}"
        d.mkdir()
        dirs.append(str(d))
    threads = [threading.Thread(target=rt.ensure_trusted, args=(d,)) for d in dirs]
    [t.start() for t in threads]
    [t.join() for t in threads]
    import os
    data = _json.loads((home / ".claude.json").read_text())
    assert all(data["projects"][os.path.realpath(d)]["hasTrustDialogAccepted"] for d in dirs)


def test_sessions_the_server_starts_carry_its_hooks(home):
    """Server sessions report to the server's own hook socket, like the Mac's do,
    through a settings file given at start (never the server's global settings:
    Jarvis's own Claude chats run there too)."""
    run = Run(stdout="backgrounded · 1a2b3c4d\n")
    rt = ClaudeRuntime(run=run, pty_factory=None, hook_settings="/srv/jc/claude-hooks.json")
    rt.start("/srv/app", prompt="hi")
    argv, _ = run.calls[-1]
    assert argv[argv.index("--settings") + 1] == "/srv/jc/claude-hooks.json"
    rt.start("/srv/app", resume_session_id="745e113e-a511")
    assert "--settings" in run.calls[-1][0]
    # A session born in the background keeps the flags it started with: adding
    # any on resume makes a copy.
    rt.start("/srv/app", resume_session_id="745e113e-a511", bg_origin=True)
    assert "--settings" not in run.calls[-1][0]


def test_job_state_reads_claudes_own_job_file(home):
    d = home / ".claude" / "jobs" / "1a2b3c4d"
    d.mkdir(parents=True)
    (d / "state.json").write_text(json.dumps({"state": "working", "tempo": "active"}))
    rt = ClaudeRuntime(run=Run())
    assert rt.job_state("1a2b3c4d")["state"] == "working"
    assert rt.job_state("ffffffff") == {}
    assert rt.job_state("../../etc") == {}
