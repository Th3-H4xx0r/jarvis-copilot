"""Windows process handling for the agents link: never os.kill(pid, 0) (it terminates the
process on Windows), stop whole trees, read the terminal from the process's environment,
launch in Windows Terminal, and read codex's app-server without select()."""
import subprocess
import sys
import types

import pytest

from jc_client import agent_roster, local_runtime, plan_usage, winproc


class P:
    def __init__(self, env=None, name="claude.exe", parent=None, kids=()):
        self._env, self._name, self._parent, self._kids = env or {}, name, parent, list(kids)
        self.terminated = self.killed = False

    def environ(self): return self._env
    def name(self): return self._name
    def parent(self): return self._parent
    def children(self, recursive=False): return self._kids
    def terminate(self): self.terminated = True
    def kill(self): self.killed = True


def _psutil(procs, alive=()):
    return types.SimpleNamespace(Process=lambda pid: procs[pid], pid_exists=lambda pid: pid in alive,
                                 wait_procs=lambda ps, timeout=0: ([], [p for p in ps if not p.terminated]),
                                 NoSuchProcess=LookupError, AccessDenied=PermissionError)


def test_pid_alive_asks_psutil_never_signals(monkeypatch):
    monkeypatch.setitem(sys.modules, "psutil", _psutil({}, alive={7}))
    assert "os.kill" not in open(winproc.__file__).read().split("\"\"\"", 2)[2]   # never signal on Windows
    assert winproc.pid_alive(7) is True and winproc.pid_alive(8) is False


def test_terminate_tree_children_first_then_kill_stragglers(monkeypatch):
    kid = P(name="node.exe")
    root = P(kids=[kid])
    monkeypatch.setitem(sys.modules, "psutil", _psutil({5: root}))
    winproc.terminate_tree(5, grace=0)
    assert kid.terminated and root.terminated


def test_terminal_from_pid_windows_terminal(monkeypatch):
    host = P(name="WindowsTerminal.exe")
    shell = P(name="pwsh.exe", parent=host)
    claude = P(env={"WT_SESSION": "abc-123"}, parent=shell)
    monkeypatch.setitem(sys.modules, "psutil", _psutil({9: claude}))
    out = winproc.terminal_from_pid(9)
    assert out == {"term_program": "windows-terminal", "wt_session": "abc-123", "exe": "WindowsTerminal.exe"}


def test_terminal_from_pid_vscode(monkeypatch):
    code = P(name="Code.exe")
    claude = P(env={"TERM_PROGRAM": "vscode", "VSCODE_PID": "100"}, parent=P(name="powershell.exe", parent=code))
    monkeypatch.setitem(sys.modules, "psutil", _psutil({9: claude}))
    out = winproc.terminal_from_pid(9)
    assert out["term_program"] == "vscode" and out["exe"] == "Code.exe" and out["window_pid"] == 100


def test_roster_uses_winproc_on_windows(monkeypatch):
    monkeypatch.setattr(agent_roster.sys, "platform", "win32")
    monkeypatch.setattr(winproc, "pid_alive", lambda pid: pid == 3)
    monkeypatch.setattr(winproc, "terminal_from_pid", lambda pid: {"term_program": "windows-terminal"})
    assert agent_roster._pid_alive(3) is True
    assert agent_roster.terminal_from_pid(3) == {"term_program": "windows-terminal"}


def test_find_claude_windows_paths(monkeypatch, tmp_path):
    monkeypatch.setattr(agent_roster.sys, "platform", "win32")
    exe = tmp_path / ".local" / "bin"
    exe.mkdir(parents=True)
    (exe / "claude.exe").write_text("")
    assert agent_roster.find_claude(home=str(tmp_path), path_env="") == str(exe / "claude.exe")


def test_open_in_windows_terminal(monkeypatch):
    monkeypatch.setattr(local_runtime.sys, "platform", "win32")
    ran = []
    rt = local_runtime.LocalRuntime(run=lambda argv, **kw: ran.append(argv) or subprocess.CompletedProcess(argv, 0),
                                    claude_bin="claude")
    where = rt.open_in_terminal(r"C:\Users\Pranav K\app", "claude --resume abc", {"term_program": "windows-terminal"})
    assert where == "windows-terminal"
    assert ran[0][:6] == ["wt.exe", "-w", "0", "nt", "-d", r"C:\Users\Pranav K\app"]
    assert ran[0][6:] == ["powershell", "-NoExit", "-Command", "claude --resume abc"]


def test_cd_line_windows_quotes_for_powershell(monkeypatch):
    monkeypatch.setattr(local_runtime.sys, "platform", "win32")
    assert local_runtime._cd_line(r"C:\it's\app", "claude") == "Set-Location -LiteralPath 'C:\\it''s\\app'; claude"


def test_stop_pid_on_windows_terminates_the_tree(monkeypatch):
    monkeypatch.setattr(local_runtime.sys, "platform", "win32")
    stopped = []
    monkeypatch.setattr(winproc, "terminate_tree", lambda pid, grace=5.0: stopped.append(pid))
    local_runtime.LocalRuntime(claude_bin="claude").stop_pid(77)
    assert stopped == [77]


def test_read_json_lines_without_select(monkeypatch):
    import io
    stream = io.BytesIO(b'{"id": 1}\n{"id": 2, "result": {"x": 1}}\n')
    got = plan_usage._first_reply_threaded(stream, 2, timeout=2.0)
    assert got == {"id": 2, "result": {"x": 1}}
