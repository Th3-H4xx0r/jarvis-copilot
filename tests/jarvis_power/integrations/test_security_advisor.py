"""Security Advisor as a Power integration: protected, seeded from plugins.enabled."""
from __future__ import annotations

from jarvis_power import discovery, state


def test_advisor_seed_follows_plugins_enabled(monkeypatch):
    import jarviscopilot_cli.plugins as plugins
    discovery.reset()
    p = discovery.get("security-advisor")
    monkeypatch.setattr(plugins, "_get_enabled_plugins", lambda: {"security_advisor"})
    assert p.seed_enabled() is True
    monkeypatch.setattr(plugins, "_get_enabled_plugins", lambda: set())
    assert p.seed_enabled() is False
    assert p.protected is True


def test_advisor_hooks_noop_while_off(reg, monkeypatch):
    discovery.reset()
    state.ensure_all()
    import jarviscopilot_cli.plugins as plugins

    registered = {}

    class Ctx:
        def register_hook(self, name, fn):
            registered[name] = fn

        def register_auxiliary_task(self, *a, **k):
            pass

        def register_tool(self, **k):
            pass

        def register_cli_command(self, **k):
            pass

    import plugins.security_advisor as advisor
    advisor.register(Ctx())
    state.write_enabled("security-advisor", False, by="app")
    assert registered["pre_tool_call"](tool_name="terminal", args={}) is None


def test_advisor_off_stops_service(reg, monkeypatch):
    discovery.reset()
    state.ensure_all()
    from plugins.security_advisor import service

    calls = []

    class Fake:
        def start(self):
            calls.append("start")

        def stop(self):
            calls.append("stop")

    monkeypatch.setattr(service.SecurityService, "instance", classmethod(lambda cls: Fake()))
    p = discovery.get("security-advisor")
    p.start("webui")
    p.stop("webui")
    assert calls == ["start", "stop"]
