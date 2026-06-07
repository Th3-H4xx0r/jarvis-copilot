"""Tests for the tray "Quit" → stop-the-background-service behaviour.

The fix: tray "Quit" must ALSO stop the supervised/background service (not just
the tray UI), reusing cli.py's per-OS stop helpers so the LaunchAgent/systemd
service is actually stopped and KeepAlive can't restart it.

These tests avoid constructing a real ``TrayApp`` (which imports pystray and a
GUI) — they drive ``_stop_supervised_service`` on a bare instance with the
``jc_client.cli`` helpers monkeypatched, asserting the right calls happen.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_tray_quit.py -q
"""

import os

import pytest

from jc_client import cli
from jc_client.tray import TrayApp


def _bare_tray() -> TrayApp:
    """A TrayApp instance without running __init__ (no pystray needed)."""
    return TrayApp.__new__(TrayApp)


def test_supervised_unloads_supervisor(monkeypatch):
    """When a supervisor is installed AND loaded, Quit unloads it
    (this is what defeats macOS KeepAlive) and does NOT try a PID kill."""
    calls = []
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: "launchctl")
    monkeypatch.setattr(cli, "_supervisor_is_loaded", lambda: True)
    monkeypatch.setattr(cli, "_supervisor_unload", lambda: calls.append("unload"))
    # No PID-file process running.
    monkeypatch.setattr(cli, "_read_pid", lambda: None)
    monkeypatch.setattr(cli, "_is_running", lambda pid: False)
    killed = []
    monkeypatch.setattr(os, "kill", lambda pid, sig: killed.append((pid, sig)))

    _bare_tray()._stop_supervised_service()

    assert calls == ["unload"], "supervisor must be unloaded"
    assert killed == [], "no PID kill when no service PID is running"


def test_no_supervisor_kills_pid(monkeypatch):
    """Windows / no-supervisor case: no supervisor, but a PID-file service is
    alive — Quit SIGTERMs it (mirrors cmd_stop's PID-file fallback)."""
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: None)
    monkeypatch.setattr(cli, "_supervisor_is_loaded", lambda: False)
    monkeypatch.setattr(cli, "_supervisor_unload",
                        lambda: pytest.fail("unload must not run without a supervisor"))
    fake_pid = os.getpid() + 1  # not our own pid
    monkeypatch.setattr(cli, "_read_pid", lambda: fake_pid)
    # Alive on the first check (so we kill), then dead.
    states = iter([True, False])
    monkeypatch.setattr(cli, "_is_running", lambda pid: next(states, False))
    killed = []
    monkeypatch.setattr(os, "kill", lambda pid, sig: killed.append((pid, sig)))
    unlinked = []
    monkeypatch.setattr(type(cli.PID_FILE), "unlink",
                        lambda self, *a, **k: unlinked.append(True))

    _bare_tray()._stop_supervised_service()

    assert killed and killed[0][0] == fake_pid, "the PID-file service must be SIGTERM'd"


def test_never_kills_self(monkeypatch):
    """Defensive: if the PID file somehow points at the tray's own pid, we
    must not SIGTERM ourselves."""
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: None)
    monkeypatch.setattr(cli, "_supervisor_is_loaded", lambda: False)
    monkeypatch.setattr(cli, "_read_pid", lambda: os.getpid())
    monkeypatch.setattr(cli, "_is_running", lambda pid: True)
    killed = []
    monkeypatch.setattr(os, "kill", lambda pid, sig: killed.append((pid, sig)))
    monkeypatch.setattr(type(cli.PID_FILE), "unlink", lambda self, *a, **k: None)

    _bare_tray()._stop_supervised_service()

    assert killed == [], "must never kill our own process"


def test_unload_exception_is_swallowed(monkeypatch):
    """A hung/raising supervisor unload must not propagate — quit can't fail."""
    def _boom():
        raise RuntimeError("launchctl blew up")
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: "launchctl")
    monkeypatch.setattr(cli, "_supervisor_is_loaded", lambda: True)
    monkeypatch.setattr(cli, "_supervisor_unload", _boom)
    monkeypatch.setattr(cli, "_read_pid", lambda: None)
    monkeypatch.setattr(cli, "_is_running", lambda pid: False)

    # Must not raise.
    _bare_tray()._stop_supervised_service()
