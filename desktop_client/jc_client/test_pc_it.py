"""pc_shell (W1): PowerShell, unelevated, PATH refreshed, killed with its children at the timeout;
admin_run (W2): refused when too long to sign, else his Face ID through the broker."""
from __future__ import annotations

import base64
import subprocess

from jc_client import skills
from jc_client.skills import pc_it

ARGV6 = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand"]


class Proc:
    def __init__(self, out=b"", err=b"", code=0, hang=False):
        self.pid, self.returncode = 4242, code
        self.out, self.err, self.hang, self.calls = out, err, hang, []

    def communicate(self, timeout=None):
        self.calls.append(timeout)
        if self.hang and len(self.calls) == 1:
            raise subprocess.TimeoutExpired("powershell.exe", timeout)
        return self.out, self.err


def _popen(proc, seen):
    def popen(argv, **kw):
        seen.append(argv)
        return proc
    return popen


def test_pc_shell_runs_powershell_encoded_with_prelude():
    seen = []
    out = pc_it.run_powershell("docker --version", 120, popen=_popen(Proc(b"Docker version 27\r\n"), seen))
    argv = seen[0]
    assert argv[:6] == ARGV6
    assert base64.b64decode(argv[6]).decode("utf-16-le") == pc_it.PRELUDE + "\n" + "docker --version"
    assert out["ok"] is True and out["exit_code"] == 0 and out["stdout"] == "Docker version 27\n"
    assert out["timed_out"] is False and out["truncated"] is False


def test_prelude_matches_the_wire_contract():
    assert pc_it.PRELUDE == (
        "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $env:WSL_UTF8='1'\n"
        "$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'"
        "+[Environment]::GetEnvironmentVariable('Path','User')")


def test_pc_shell_timeout_kills_tree_and_reports_timed_out():
    killed = []
    proc = Proc(b"pulling", hang=True)
    out = pc_it.run_powershell("docker run hello-world", 120, popen=_popen(proc, []), kill_tree=killed.append)
    assert killed == [4242] and proc.calls[0] == 120
    assert out["exit_code"] is None and out["timed_out"] is True and out["stdout"] == "pulling"


def test_pc_shell_caps_output_tail():
    out = pc_it.run_powershell("x", 60, popen=_popen(Proc(b"a" * 8000 + b"b" * 12000, b"e" * 5000), []))
    assert out["stdout"] == "b" * 12000 and len(out["stderr"]) == 4000 and out["truncated"] is True


def test_pc_shell_clamps_timeout():
    p1, p2 = Proc(), Proc()
    pc_it.run_powershell("x", 0, popen=_popen(p1, []))
    pc_it.run_powershell("x", 99999, popen=_popen(p2, []))
    assert p1.calls == [5] and p2.calls == [1800]


def test_clixml_errors_read_as_text():
    err = ('#< CLIXML\r\n<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">'
           '<S S="Error">wsl : The term &apos;wsl&apos; is not recognized_x000D__x000A_</S>'
           '<S S="Error">At line:1 char:1_x000D__x000A_</S></Objs>')
    out = pc_it.run_powershell("wsl", 30, popen=_popen(Proc(b"", err.encode(), code=1), []))
    assert out["stderr"] == "wsl : The term 'wsl' is not recognized\nAt line:1 char:1"


def test_watchdog_covers_long_skills():
    pc_it.register()
    assert skills.watchdog_s("pc_shell", {"timeout_s": 600}) == 615
    assert skills.watchdog_s("admin_run", {"timeout_s": 600}) == 750
    assert skills.watchdog_s("admin_run", {}) == 750
    assert skills.watchdog_s("open_app", {}) == 20.0


class Passwords:
    def __init__(self):
        self.calls = []

    def request(self, kind, context, **kw):
        self.calls.append((kind, context, kw))
        return {"ok": True, "status": "ran", "exit_code": 0, "output": "ok"}


class Power:
    def __init__(self):
        self.passwords = Passwords()


def test_admin_run_refuses_long_command_without_truncating():
    power = Power()
    pc_it.set_power(power)
    out = pc_it.admin_run("x" * 2401, "why", 600)
    assert out["status"] == "refused" and out["error"] == "command too long to sign (max 2400 characters)"
    assert power.passwords.calls == []


def test_admin_run_asks_face_id_with_the_exact_command():
    power = Power()
    pc_it.set_power(power)
    pc_it.admin_run("wsl --install --no-distribution  ", "Enable WSL2", 900)
    assert power.passwords.calls == [("admin-run", "wsl --install --no-distribution  ",
                                      {"why": "Enable WSL2", "run_timeout": 900})]
    pc_it.admin_run("winget remove x", "clean up", 300, elevated=False)
    assert power.passwords.calls[-1][0] == "pc-run"


def test_admin_run_without_pc_power():
    pc_it.set_power(None)
    out = pc_it.admin_run("dism /online", "x", 600)
    assert out["ok"] is False and out["status"] == "failed" and out["error"] == "PC power isn't running in jc-client"
