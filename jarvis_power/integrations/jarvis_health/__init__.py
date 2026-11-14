"""Jarvis Health: your wearables' days, sleep, workouts, habits and weight.

Off: the Health tab, health widget and workout Live Activity hide and the analysis
schedule pauses — but uploads keep landing, so nothing your ring or scale records
is lost. Its old "enabled" setting only ever meant "run analysis", so it's the
"Analysis & alerts" setting here. Ring and band connections stay (other features
use them).
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration, Setting

SPACE = "jarvis-health"
_FREQUENCIES = (("hourly", "Every hour"), ("every 6 hours", "Every 6 hours"),
                ("every 12 hours", "Every 12 hours"), ("daily", "Daily"), ("manual", "Only when I ask"))


def _health_store():
    from jarvis_health.store import HealthStore
    return HealthStore(SPACE)


class JarvisHealth(PowerIntegration):
    id = "jarvis-health"
    name = "Jarvis Health"
    icon = "heart.text.square.fill"
    summary = "Your wearables' days, sleep, workouts, habits and weight in one place."
    adopt_space = True
    route_prefixes = ("/api/integrations/jarvis-health/health/run",)
    surfaces = ("ios.tab.health", "ios.widget.health", "ios.liveactivity.workout")
    links = (Link("ios", "health_tab", "Open Health"),)
    settings = (
        Setting("analysis", "Analysis & alerts", "toggle", default=True,
                help="Jarvis reads your days on a schedule and tells you what stands out."),
        Setting("frequency", "How often", "picker", default="every 6 hours", options=_FREQUENCIES),
    )

    def read_settings(self) -> dict:
        current = _health_store().settings()
        return {"analysis": bool(current.get("enabled", True)),
                "frequency": current.get("frequency") or "every 6 hours"}

    def write_settings(self, changes: dict) -> None:
        updates = {}
        if "analysis" in changes:
            updates["enabled"] = bool(changes["analysis"])
        if "frequency" in changes:
            updates["frequency"] = changes["frequency"]
        settings = _health_store().put_settings(updates)
        from jarvis_health.bootstrap import ensure_schedule
        ensure_schedule(settings)

    def status_line(self) -> str:
        days = _health_store().dates(1)
        return f"Last day {days[0]}" if days else "Waiting for your wearables"
