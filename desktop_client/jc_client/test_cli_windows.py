"""jc-client's CLI on Windows: Task Scheduler supervises it, and checking a pid never kills it."""
import subprocess
import types

from jc_client import cli


def _cp(rc=0, out=""):
    return subprocess.CompletedProcess(args=[], returncode=rc, stdout=out, stderr="")


def test_is_running_never_signals_on_windows(monkeypatch):
    monkeypatch.setattr(cli.sys, "platform", "win32")
    killed = []
    monkeypatch.setattr(cli.os, "kill", lambda *a: killed.append(a))
    fake = types.SimpleNamespace(pid_exists=lambda pid: pid == 42)
    monkeypatch.setitem(__import__("sys").modules, "psutil", fake)
    assert cli._is_running(42) is True
    assert cli._is_running(7) is False
    assert killed == []          # os.kill(pid, 0) would terminate the process on Windows


def test_supervisor_kind_schtasks(monkeypatch):
    monkeypatch.setattr(cli.sys, "platform", "win32")
    calls = []
    monkeypatch.setattr(cli, "_schtasks", lambda *a: calls.append(a) or _cp(0))
    assert cli._supervisor_kind() == "schtasks"
    assert calls[0] == ("/Query", "/TN", "\\JarvisCopilot\\jc-client")
    monkeypatch.setattr(cli, "_schtasks", lambda *a: _cp(1))
    assert cli._supervisor_kind() is None


def test_schtasks_load_unload_and_running(monkeypatch):
    monkeypatch.setattr(cli.sys, "platform", "win32")
    calls = []

    def fake(*a):
        calls.append(a)
        if "/FO" in a:
            return _cp(0, "TaskName: \\JarvisCopilot\\jc-client\nStatus: Running\n")
        return _cp(0)
    monkeypatch.setattr(cli, "_schtasks", fake)
    assert cli._supervisor_is_loaded() is True
    cli._supervisor_load()
    cli._supervisor_unload()
    assert ("/Run", "/TN", "\\JarvisCopilot\\jc-client") in calls
    assert ("/End", "/TN", "\\JarvisCopilot\\jc-client") in calls
