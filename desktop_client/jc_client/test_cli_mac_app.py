"""On a Mac, Jarvis lives in the notch (Jarvis.app): `jc-client start` runs the
background client and opens the app — never the retired Python tray."""
import argparse
import signal
import subprocess

import pytest

from jc_client import cli


class Calls:
    def __init__(self):
        self.run, self.popen, self.killed = [], [], []


@pytest.fixture
def mac(monkeypatch, tmp_path):
    calls = Calls()
    monkeypatch.setattr(cli, "_is_mac", lambda: True)
    monkeypatch.setattr(cli, "TRAY_PID_FILE", tmp_path / "tray.pid")
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: "launchd")
    monkeypatch.setattr(cli, "_supervisor_is_loaded", lambda: True)
    monkeypatch.setattr(cli, "_read_pid", lambda: 111)
    monkeypatch.setattr(cli, "_is_running", lambda pid: True)

    def run(cmd, **kw):
        calls.run.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 0, b"", b"")

    monkeypatch.setattr(cli.subprocess, "run", run)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda cmd, **kw: calls.popen.append(list(cmd)))
    monkeypatch.setattr(cli.os, "kill", lambda pid, sig: calls.killed.append((pid, sig)))
    return calls


def _opened_app(calls):
    return any(c[:1] == ["open"] and "com.jarviscopilot.mac" in c for c in calls.run)


def test_start_opens_the_island_and_never_the_tray(mac, monkeypatch):
    cli.TRAY_PID_FILE.write_text("222")        # an old tray still running
    assert cli.cmd_start(argparse.Namespace(no_tray=False, verbose=False)) == 0
    assert _opened_app(mac)
    assert (222, signal.SIGTERM) in mac.killed
    assert not any("tray" in c for cmd in mac.popen for c in cmd)


def test_start_without_a_supervisor_runs_the_client_headless(mac, monkeypatch):
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: None)
    monkeypatch.setattr(cli, "_read_pid", lambda: None)
    assert cli.cmd_start(argparse.Namespace(no_tray=False, verbose=False)) == 0
    assert mac.popen and mac.popen[0][-3:] == ["jc_client", "start", "--no-tray"]
    assert _opened_app(mac)


def test_stop_also_quits_the_island(mac, monkeypatch):
    monkeypatch.setattr(cli, "_supervisor_unload", lambda: None)
    cli.cmd_stop(argparse.Namespace())
    assert any(c[:1] == ["pkill"] and "Jarvis" in c[-1] for c in mac.run)


def test_tray_opens_the_island_instead(mac, monkeypatch):
    def no_tray():
        raise AssertionError("the Python tray must not run on a Mac")
    monkeypatch.setattr("jc_client.tray.run", no_tray, raising=False)
    assert cli.cmd_tray(argparse.Namespace()) == 0
    assert _opened_app(mac)


def test_restart_brings_the_island_back(mac, monkeypatch):
    monkeypatch.setattr(cli, "_supervisor_unload", lambda: None)
    monkeypatch.setattr(cli, "_supervisor_load", lambda: None)
    monkeypatch.setattr(cli, "_wait_supervisor", lambda loaded: True)
    assert cli.cmd_restart(argparse.Namespace()) == 0
    assert _opened_app(mac)
