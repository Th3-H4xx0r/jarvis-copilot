"""Security Advisor: watches devices, the server and the agent for misuse; blocks
clear attacks, alerts the phone, digests the rest.

Protected: switching it off needs Face ID on the iPhone (so a prompt injection can't
get Jarvis to turn it off). Off: its worker stops, its guard hooks don't fire, IP
blocks aren't enforced, its tools are refused and its screens hide.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration, Setting


def _ensure_plugin_listed() -> None:
    try:
        from jarvis_power.stores import config_get, config_set
        enabled = list(config_get("plugins.enabled", []) or [])
        if "security_advisor" not in enabled:
            config_set("plugins.enabled", enabled + ["security_advisor"])
    except Exception:
        pass


class SecurityAdvisor(PowerIntegration):
    id = "security-advisor"
    name = "Security Advisor"
    icon = "shield.lefthalf.filled"
    summary = "Watches devices, the server and Jarvis for misuse; blocks clear attacks."
    protected = True
    processes = ("webui",)
    toolsets = ("security_advisor",)
    route_prefixes = ("/api/security",)
    surfaces = ("ios.more.security", "ios.deeplink.security", "ios.push.security_alert",
                "web.rail.security")
    links = (Link("ios", "security", "Open Security"), Link("web", "security", "Open Security"))
    settings = (
        Setting("alert_cap_per_hour", "Alerts per hour at most", "number", default=3,
                min=0, max=60, jarvis="ask"),
        Setting("block_ttl_hours", "Block an attacker for (hours)", "number", default=24,
                min=1, max=720, jarvis="ask"),
        Setting("digest_hour", "Daily digest at (hour)", "number", default=8, min=0, max=23),
    )

    def seed_enabled(self) -> bool:
        from jarviscopilot_cli.plugins import _get_enabled_plugins
        return "security_advisor" in (_get_enabled_plugins() or set())

    def start(self, process: str) -> None:
        # The plugin (its guard hooks, tools, CLI) is opt-in via plugins.enabled; keep it
        # listed while this is on so every process loads it. Off leaves it listed — its
        # hooks are gated on this switch — so switching back on needs no restart.
        _ensure_plugin_listed()
        from plugins.security_advisor.service import SecurityService
        SecurityService.instance().start()

    def stop(self, process: str) -> None:
        from plugins.security_advisor.service import SecurityService
        SecurityService.instance().stop()

    def read_settings(self) -> dict:
        from plugins.security_advisor import settings
        current = settings.load()
        return {s.key: current.get(s.key, s.default) for s in self.settings}

    def write_settings(self, changes: dict) -> None:
        from plugins.security_advisor import settings
        settings.save({k: int(v) for k, v in changes.items()})
