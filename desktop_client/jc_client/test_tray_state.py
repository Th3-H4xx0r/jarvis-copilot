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
    """Neither source knows of a live service: that is the one honest red."""
    monkeypatch.setattr(tray, "_read_service_pid", lambda: None)
    monkeypatch.setattr(tray, "_service_pid_from_state", lambda: None)
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


def test_a_missing_pid_file_falls_back_to_what_the_service_recorded(monkeypatch):
    """The PID file can be absent while the service is alive and connected.

    It is written by `jc-client start` and removed by `jc-client stop`, so it
    describes how a service was launched, not whether one is running. The state
    file is written by the service about itself.
    """
    monkeypatch.setattr(tray, "_read_service_pid", lambda: None)
    monkeypatch.setattr(tray, "_service_pid_from_state", lambda: 84625)
    assert _bare_tray()._supervised_pid == 84625


def test_the_pid_file_still_wins_when_it_is_there(monkeypatch):
    monkeypatch.setattr(tray, "_read_service_pid", lambda: 11)
    monkeypatch.setattr(tray, "_service_pid_from_state", lambda: 22)
    assert _bare_tray()._supervised_pid == 11


def test_a_dead_pid_in_the_state_file_is_not_believed(monkeypatch, tmp_path):
    """Otherwise a crashed service's leftover record would read as connected."""
    import json
    (tmp_path / "connection_state.json").write_text(
        json.dumps({"state": "connected", "pid": 999999}))
    monkeypatch.setattr(tray, "state_dir", lambda: tmp_path)
    monkeypatch.setattr("jc_client.logger.state_dir", lambda: tmp_path)
    monkeypatch.setattr(tray, "_pid_alive", lambda pid: False)
    assert tray._service_pid_from_state() is None


def test_a_live_pid_in_the_state_file_is(monkeypatch, tmp_path):
    import json
    (tmp_path / "connection_state.json").write_text(
        json.dumps({"state": "connected", "pid": 4242}))
    monkeypatch.setattr("jc_client.logger.state_dir", lambda: tmp_path)
    monkeypatch.setattr(tray, "_pid_alive", lambda pid: True)
    assert tray._service_pid_from_state() == 4242
