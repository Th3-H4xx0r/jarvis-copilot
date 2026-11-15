"""PC Stats as a Power integration: valid manifest; off refuses its routes and tools."""
from __future__ import annotations

from jarvis_power import discovery, gate, state


def test_pc_stats_validates_and_gates(reg):
    discovery.reset()
    p = discovery.get("pc-stats")
    assert discovery.validate(p) == []
    state.ensure_all()
    assert gate.route_block("/api/pc-stats/live") is None
    state.write_enabled("pc-stats", False, by="app")
    assert gate.route_block("/api/pc-stats/live")["power_off"] == "pc-stats"
    assert gate.route_block("/api/pc-stats/samples")["power_off"] == "pc-stats"
    assert gate.tool_off_message("pc_stats") == "PC Stats is switched off"
