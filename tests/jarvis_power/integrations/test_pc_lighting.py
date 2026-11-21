"""PC Lighting as a Power integration: valid manifest; off refuses its routes and tools; status line."""
from __future__ import annotations

from jarvis_power import discovery, gate, state


def test_pc_lighting_validates_and_gates(reg):
    discovery.reset()
    p = discovery.get("pc-lighting")
    assert discovery.validate(p) == []
    state.ensure_all()
    assert gate.route_block("/api/pc-lighting/state") is None
    state.write_enabled("pc-lighting", False, by="app")
    assert gate.route_block("/api/pc-lighting/state")["power_off"] == "pc-lighting"
    assert gate.route_block("/api/pc-specs") is None          # specs aren't lighting: never gated
    assert gate.tool_off_message("pc_lighting") == "PC Lighting is switched off"


def test_address_setting_is_app_only(reg):
    discovery.reset()
    p = discovery.get("pc-lighting")
    (address,) = [s for s in p.settings if s.key == "address"]
    assert address.default == "127.0.0.1:6742" and address.jarvis == "never"


def test_start_and_stop_follow_the_switch(reg, monkeypatch):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))
    import api.pc_lighting_routes as routes
    seen = []
    monkeypatch.setattr(routes, "power_changed", lambda enabled: seen.append(enabled))
    discovery.reset()
    p = discovery.get("pc-lighting")
    p.stop("webui")
    p.start("webui")
    assert seen == [False, True]


def test_status_line_says_what_is_missing(reg, monkeypatch):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))
    import api.pc_lighting_routes as routes
    discovery.reset()
    p = discovery.get("pc-lighting")
    monkeypatch.setattr(routes, "summary", lambda: {"device_id": "", "online": False})
    assert p.status_line() == "Waiting for the PC"
    monkeypatch.setattr(routes, "summary", lambda: {"device_id": "pc-1", "online": True, "mapped": False})
    assert p.status_line() == "Set up lighting"
    monkeypatch.setattr(routes, "summary", lambda: {"device_id": "pc-1", "online": True, "mapped": True,
                                                    "on": True, "effect": "rainbow", "brightness": 65})
    assert p.status_line() == "Rainbow · 65%"
