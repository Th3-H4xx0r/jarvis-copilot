"""Starting, resuming and stopping agent sessions on this Mac — no tmux."""
import json
import signal
import subprocess

from jc_client.local_runtime import LocalRuntime


class FakeVSCode:
    def __init__(self, ok=True):
        self.ok, self.runs, self.sent = ok, [], []

    def run_in_terminal(self, cwd, command, timeout=3.0):
        self.runs.append((cwd, command))
        return self.ok

    def send_text(self, shell_pid, text, timeout=3.0):
        self.sent.append((shell_pid, text))
        return self.ok

    def terminal_pid_for(self, pid):
        return 4000 if pid == 4001 else None


class Rec:
    def __init__(self, stdout=""):
        self.calls, self.stdout = [], stdout

    def __call__(self, argv, **kw):
        self.calls.append(argv)
        out = kw.get("stdout")
        if hasattr(out, "write"):
            out.write(self.stdout)
            out.flush()
        return subprocess.CompletedProcess(argv, 0, None, None)


def test_resume_prefers_vscode_when_term_program_vscode():
    vs, run = FakeVSCode(), Rec()
    rt = LocalRuntime(run=run, vscode=vs)
    via = rt.resume_in_terminal("claude", "s1", "/Users/p/app", {"term_program": "vscode"})
    assert via == "vscode"
    assert vs.runs == [("/Users/p/app", "claude --resume s1")]


def test_resume_in_same_vscode_terminal_after_stopping_stale():
    vs, run = FakeVSCode(), Rec()
    killed = []
    rt = LocalRuntime(run=run, vscode=vs, kill=lambda pid, sig: killed.append((pid, sig)),
                      alive=lambda pid: False)
    via = rt.resume_in_terminal("codex", "c1", "/Users/p/app", {"term_program": "vscode"},
                                stale_pid=4001)
    assert via == "vscode" and killed[0] == (4001, signal.SIGINT)
    assert vs.sent == [(4000, "cd /Users/p/app && codex resume c1")]


def test_resume_falls_back_to_terminal_app():
    run = Rec()
    rt = LocalRuntime(run=run, vscode=FakeVSCode(ok=False))
    via = rt.resume_in_terminal("claude", "s1", "/Users/p/my app", {"term_program": "ghostty"})
    assert via == "terminal"
    argv = run.calls[-1]
    assert argv[0] == "/usr/bin/osascript" and "cd '/Users/p/my app' && claude --resume s1" in argv


def test_stop_escalates():
    seen, alive = [], {"n": 0}

    def is_alive(pid):
        alive["n"] += 1
        return True

    rt = LocalRuntime(kill=lambda pid, sig: seen.append(sig), alive=is_alive, grace=0.05)
    rt.stop_pid(77)
    assert seen == [signal.SIGINT, signal.SIGTERM]


def test_launch_bg_parses_id_and_trusts(tmp_path, monkeypatch):
    import os
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    run = Rec(stdout="backgrounded · ab12cd34\n")
    rt = LocalRuntime(run=run)
    assert rt.launch_bg(str(tmp_path), prompt="hi", model="claude-sonnet-5-5") == "ab12cd34"
    argv = run.calls[-1]
    # launchd's PATH lacks Claude's install dir: the executable is resolved
    assert os.path.basename(argv[0]) == "claude" and argv[1] == "--bg" and argv[-1] == "hi"
    cfg = json.loads((tmp_path / ".claude.json").read_text())
    import os
    assert cfg["projects"][os.path.realpath(str(tmp_path))]["hasTrustDialogAccepted"] is True
