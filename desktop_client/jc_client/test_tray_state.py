"""The tray's view of the service it is watching.

The tray outlives the service: `jc-client restart`, `jc-client update` and the
supervisor's own crash recovery each hand the service a NEW pid while the
menubar item keeps running. A tray that remembered the old one reported the
service as stopped forever — red icon, "Reconnecting…" — over a perfectly
healthy connection.
"""
from __future__ import annotations

from jc_client import tray
from jc_client.tray import TrayApp


def _bare_tray(supervised: bool = True) -> TrayApp:
    app = TrayApp.__new__(TrayApp)
    app._supervised = supervised
    return app


def test_the_watched_pid_follows_a_service_restart(monkeypatch):
    live = {"pid": 100}
    monkeypatch.setattr(tray, "_read_service_pid", lambda: live["pid"])
    app = _bare_tray()
    assert app._supervised_pid == 100
    live["pid"] = 200                      # the service restarted under us
    assert app._supervised_pid == 200, "the tray must re-read, not remember"


def test_nothing_is_watched_when_the_tray_owns_the_service(monkeypatch):
    """In-process mode reads `self._svc` directly; a pid would be misleading."""
    monkeypatch.setattr(tray, "_read_service_pid", lambda: 100)
    assert _bare_tray(supervised=False)._supervised_pid is None


def test_a_gone_service_reads_as_stopped(monkeypatch):
    monkeypatch.setattr(tray, "_read_service_pid", lambda: None)
    assert _bare_tray()._supervised_pid is None
    assert tray._supervised_state(None) == "stopped"


def test_the_state_file_is_trusted_when_it_names_the_live_service(monkeypatch):
    """The pid match is what rejects a stale file from a previous run — it must
    still ACCEPT the current one, which is the case that broke."""
    monkeypatch.setattr(tray, "_read_service_pid", lambda: 4242)
    monkeypatch.setattr(tray, "_pid_alive", lambda pid: True)
    monkeypatch.setattr(tray, "_read_connection_state",
                        lambda pid: "connected" if pid == 4242 else None)
    assert tray._supervised_state(_bare_tray()._supervised_pid) == "connected"
