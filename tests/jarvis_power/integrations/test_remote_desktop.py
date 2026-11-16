"""Remote Desktop as a Power integration: valid manifest; off refuses its routes and tools."""
from __future__ import annotations

from jarvis_power import discovery, gate, state


def test_remote_desktop_validates_and_gates(reg):
    discovery.reset()
    p = discovery.get("remote-desktop")
    assert discovery.validate(p) == []
    assert p.route_prefixes == ("/api/rdp",)
    assert p.toolsets == ("remote_desktop",)
    assert {s.key for s in p.settings} >= {"idle_minutes", "warn_game", "allow_web", "transfer_folder"}
    defaults = {s.key: s.default for s in p.settings}
    assert defaults["idle_minutes"] == 30 and defaults["warn_game"] is True and defaults["allow_web"] is True
    state.ensure_all()
    assert gate.route_block("/api/rdp/sessions") is None
    state.write_enabled("remote-desktop", False, by="app")
    assert gate.route_block("/api/rdp/sessions")["power_off"] == "remote-desktop"
    assert gate.route_block("/api/rdp/relay/abc")["power_off"] == "remote-desktop"


def test_stop_cancels_every_session(reg, monkeypatch):
    discovery.reset()
    called = []
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))
    from api import rdp_sessions
    monkeypatch.setattr(rdp_sessions, "on_off", lambda: called.append(True))
    discovery.get("remote-desktop").stop("webui")
    assert called == [True]
