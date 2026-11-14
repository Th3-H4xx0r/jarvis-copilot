"""The Car as a Power integration: protected; off never touches the shared Face ID approver."""
from __future__ import annotations

from jarvis_power import discovery, gate, state


def test_car_off_keeps_approver_routes(reg):
    discovery.reset()
    state.ensure_all()
    state.write_enabled("car", False, by="app")
    assert gate.route_block("/api/car/state")["power_off"] == "car"
    assert gate.route_block("/api/car/command")["power_off"] == "car"
    for path in ("/api/car/approver", "/api/car/approver/button",
                 "/api/car/approvals", "/api/car/approvals/abc/approve"):
        assert gate.route_block(path) is None, path


def test_car_hooks_noop_while_off(reg):
    discovery.reset()
    state.ensure_all()
    registered = {}

    class Ctx:
        def register_tool(self, **k):
            pass

        def register_hook(self, name, fn):
            registered[name] = fn

    import plugins.toyota as toyota
    toyota.register(Ctx())
    state.write_enabled("car", False, by="app")
    assert registered["pre_llm_call"](session_id="s", user_message="yes") is None


def test_car_is_protected_and_owns_toyota_tools():
    discovery.reset()
    p = discovery.get("car")
    assert p.protected and "toyota" in p.toolsets
    assert discovery.validate(p) == []
