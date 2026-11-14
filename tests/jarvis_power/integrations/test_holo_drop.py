"""Holo Drop as a Power integration: valid manifest, off refuses its routes and tool."""
from __future__ import annotations

from jarvis_power import discovery, gate, state


def test_holo_drop_validates_and_gates(reg):
    discovery.reset()
    p = discovery.get("holo-drop")
    assert discovery.validate(p) == []
    state.ensure_all()
    state.write_enabled("holo-drop", False, by="app")
    assert gate.route_block("/api/holo-drop/drops")["power_off"] == "holo-drop"
    assert gate.tool_off_message("holo_drop") == "Holo Drop is switched off"
