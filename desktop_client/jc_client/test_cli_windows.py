"""jc-client's CLI on Windows: Task Scheduler supervises it, and checking a pid never kills it."""
import subprocess
import types

import pytest

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
    # stop disables the task (its 5-minute watch would start it again); start enables it first
    i_dis = calls.index(("/Change", "/TN", "\\JarvisCopilot\\jc-client", "/DISABLE"))
    assert i_dis < calls.index(("/End", "/TN", "\\JarvisCopilot\\jc-client"))
    assert calls.index(("/Change", "/TN", "\\JarvisCopilot\\jc-client", "/ENABLE")) < calls.index(("/Run", "/TN", "\\JarvisCopilot\\jc-client"))


def test_windows_powershell_scripts_are_ascii():
    """Windows PowerShell 5.1 reads a BOM-less script as Windows-1252: the UTF-8 bytes of an
    em dash end in 0x94, a curly quote it treats as a real quote, and the script stops parsing."""
    from pathlib import Path
    root = Path(__file__).resolve().parents[2]
    for rel in ("desktop_client/installers/install-windows.ps1", "scripts/windows/setup-pc.ps1"):
        path = root / rel
        if path.exists():
            assert path.read_bytes().isascii(), rel


def test_headless_pair_sends_the_cloudflare_token(monkeypatch):
    """Behind Cloudflare Access the claim 302s without the service token (seen on the PC)."""
    seen = {}

    class FakeClient:
        def __init__(self, url, **kw):
            seen.update(kw)

        def post_json(self, path, body):
            raise RuntimeError("stop here")
    from jc_client import protocol
    monkeypatch.setattr(protocol, "HttpClient", FakeClient)   # the claim lives in pair_listener now
    monkeypatch.setenv("JC_CF_CLIENT_ID", "cid")
    monkeypatch.setenv("JC_CF_CLIENT_SECRET", "csec")
    args = types.SimpleNamespace(server="https://x", code="ABC-123", name="pc", cf_id=None, cf_secret=None)
    assert cli.cmd_pair(args) == 1
    assert seen["cf_client_id"] == "cid" and seen["cf_client_secret"] == "csec"


# ── the scheduled task's client exits when its link stays silent (live 2026-11-23) ──
class _Start:
    no_tray, boot, verbose = True, False, False


def test_the_supervised_start_hands_the_service_its_pid_file(monkeypatch, tmp_path):
    from jc_client import boot_mode
    seen = []
    monkeypatch.setattr(cli, "PID_FILE", tmp_path / "jc-client.pid")
    monkeypatch.setattr(boot_mode, "stop_boot_instance", lambda *a, **k: False)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False, **kw: seen.append(kw) or 0)
    assert cli.cmd_start(_Start()) == 0
    assert seen == [{"pid_file": tmp_path / "jc-client.pid"}]


def test_the_boot_start_hands_the_service_its_own_pid_file(monkeypatch, tmp_path):
    from jc_client import boot_mode
    seen = []
    monkeypatch.setattr(cli, "PID_FILE", tmp_path / "jc-client.pid")
    monkeypatch.setattr(cli, "BOOT_PID_FILE", tmp_path / "jc-client-boot.pid")
    monkeypatch.setattr(boot_mode, "user_signed_in", lambda *a, **k: False)
    monkeypatch.setattr(boot_mode, "watch", lambda pid_file=None: None)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False, **kw: seen.append(kw) or 0)
    monkeypatch.delenv(boot_mode.ENV, raising=False)

    class Boot(_Start):
        boot = True
    assert cli.cmd_start(Boot()) == 0
    assert seen == [{"pid_file": tmp_path / "jc-client-boot.pid"}]


# ── stale pid files: after a power cut the leftover PID can be another program's ──
class _Proc:
    def __init__(self, name, cmdline):
        self._name, self._cmdline = name, cmdline

    def name(self):
        return self._name

    def cmdline(self):
        return self._cmdline


JC = _Proc("python.exe", [r"C:\\Users\\krish\\jc\\.venv\\Scripts\\python.exe",
                          r"C:\\Users\\krish\\jc\\.venv\\Scripts\\jc-client.exe", "start", "--no-tray"])
CHROME = _Proc("chrome.exe", [r"C:\\Program Files\\Google\\Chrome\\chrome.exe"])


def _psutil(monkeypatch, procs, boot_time=0.0):
    class NoSuchProcess(Exception):
        pass

    class AccessDenied(Exception):
        pass

    def process(pid):
        if pid not in procs:
            raise NoSuchProcess(pid)
        return procs[pid]
    fake = types.SimpleNamespace(pid_exists=lambda pid: pid in procs, Process=process,
                                 boot_time=lambda: boot_time, NoSuchProcess=NoSuchProcess, AccessDenied=AccessDenied)
    monkeypatch.setitem(__import__("sys").modules, "psutil", fake)


@pytest.fixture
def pid_files(monkeypatch, tmp_path):
    monkeypatch.setattr(cli.sys, "platform", "win32")
    monkeypatch.setattr(cli, "PID_FILE", tmp_path / "jc-client.pid")
    monkeypatch.setattr(cli, "BOOT_PID_FILE", tmp_path / "jc-client-boot.pid")
    return tmp_path


def test_a_pid_file_whose_pid_is_now_another_program_is_stale(monkeypatch, pid_files):
    cli.PID_FILE.write_text("4242")
    _psutil(monkeypatch, {4242: CHROME})
    assert cli._read_pid() is None
    _psutil(monkeypatch, {4242: JC})
    assert cli._read_pid() == 4242


def test_a_pid_file_from_before_this_boot_is_stale(monkeypatch, pid_files):
    import os
    import time
    cli.PID_FILE.write_text("4242")
    os.utime(cli.PID_FILE, (time.time() - 7200, time.time() - 7200))
    _psutil(monkeypatch, {4242: JC}, boot_time=time.time() - 600)
    assert cli._read_pid() is None


def test_the_client_starts_over_a_stale_pid_file(monkeypatch, pid_files):
    from jc_client import boot_mode
    ran = []
    cli.PID_FILE.write_text("4242")
    _psutil(monkeypatch, {4242: CHROME})
    monkeypatch.setattr(boot_mode, "stop_boot_instance", lambda *a, **k: False)
    monkeypatch.setattr(cli.credentials, "refresh_boot_copy", lambda: None)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False, **kw: ran.append(1) or 0)
    assert cli.cmd_start(_Start()) == 0 and ran == [1]


def test_the_boot_instance_ignores_stale_pid_files(monkeypatch, pid_files):
    from jc_client import boot_mode
    ran = []
    cli.PID_FILE.write_text("4242")
    cli.BOOT_PID_FILE.write_text("4343")
    _psutil(monkeypatch, {4242: CHROME, 4343: _Proc("svchost.exe", ["svchost.exe", "-k", "netsvcs"])})
    monkeypatch.setattr(boot_mode, "user_signed_in", lambda *a, **k: False)
    monkeypatch.setattr(boot_mode, "watch", lambda pid_file=None: None)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False, **kw: ran.append(1) or 0)
    monkeypatch.delenv(boot_mode.ENV, raising=False)

    class Boot(_Start):
        boot = True
    assert cli.cmd_start(Boot()) == 0 and ran == [1]


def test_taking_over_from_boot_never_kills_an_unrelated_process(monkeypatch, pid_files):
    killed = []
    cli.BOOT_PID_FILE.write_text("4343")
    _psutil(monkeypatch, {4343: _Proc("explorer.exe", [r"C:\\Windows\\explorer.exe"])})
    monkeypatch.setattr(cli, "_kill_boot", lambda pid: killed.append(pid))
    monkeypatch.setattr(cli.credentials, "refresh_boot_copy", lambda: None)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False, **kw: 0)
    assert cli.cmd_start(_Start()) == 0
    assert killed == [] and not cli.BOOT_PID_FILE.exists()


def test_taking_over_from_a_real_boot_instance_still_stops_it(monkeypatch, pid_files):
    procs = {4343: _Proc("python.exe", ["python.exe", r"C:\\x\\jc-client.exe", "start", "--no-tray", "--boot"])}
    killed = []
    cli.BOOT_PID_FILE.write_text("4343")
    _psutil(monkeypatch, procs)
    monkeypatch.setattr(cli, "_kill_boot", lambda pid: killed.append(pid) or procs.pop(pid))
    monkeypatch.setattr(cli.credentials, "refresh_boot_copy", lambda: None)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False, **kw: 0)
    assert cli.cmd_start(_Start()) == 0
    assert killed == [4343]
