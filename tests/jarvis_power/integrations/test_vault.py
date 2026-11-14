"""The Vault as a Power integration: protected; off refuses its tools and routes."""
from __future__ import annotations

import json

from jarvis_power import discovery, gate, state


def test_vault_off_refuses_tools_and_routes(reg):
    discovery.reset()
    state.ensure_all()
    state.write_enabled("vault", False, by="app")
    assert gate.route_block("/api/vault/items")["power_off"] == "vault"
    assert gate.route_block("/api/vault/approvals/abc/deny") is None
    assert gate.tool_off_message("vault") == "Vault is switched off"
    import model_tools  # noqa: F401 — registers the vault tools
    from tools.registry import registry
    out = json.loads(registry.dispatch("vault_list", {}))
    assert out == {"error": "Vault is switched off"}
