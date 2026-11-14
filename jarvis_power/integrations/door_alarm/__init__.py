"""The door alarm: the Smart Life PHYSEN hub as a security alarm.

Protected, and it can only be switched off while disarmed. Off: the alarm service
stops (bridge events, Tuya cloud feed, 1 s timer), its tools and routes refuse,
and the phone hides its card, alert screen and button states. Jarvis can never
change its settings (as before).
"""
from __future__ import annotations

from typing import Optional

from jarvis_power import Link, PowerIntegration, Setting

_ALARM_KEYS = ("exit_delay", "entry_delay", "siren_duration")


def _service():
    from plugins.door_alarm.service import DoorService
    return DoorService.instance()


class DoorAlarm(PowerIntegration):
    id = "door-alarm"
    name = "Door alarm"
    icon = "door.left.hand.closed"
    summary = "Your door sensors as a security alarm, with Face ID to disarm."
    protected = True
    processes = ("webui",)
    toolsets = ("door_alarm",)
    route_prefixes = ("/api/door",)
    route_exempt = ("/api/door/approvals",)
    surfaces = ("ios.devices.door", "ios.bridge.door", "ios.alert.door", "ios.controls.door")
    links = (Link("ios", "door_page", "Open Door alarm"),)
    settings = (
        Setting("exit_delay", "Exit delay", "number", default=60, min=0, max=300, unit="s",
                jarvis="never"),
        Setting("entry_delay", "Entry delay", "number", default=30, min=0, max=300, unit="s",
                jarvis="never"),
        Setting("siren_duration", "Siren runs for", "number", default=180, min=10, max=900,
                unit="s", jarvis="never"),
    )

    def can_switch_off(self) -> Optional[str]:
        if _service().alarm.state != "disarmed":
            return "Disarm the alarm first"
        return None

    def start(self, process: str) -> None:
        _service().start()

    def stop(self, process: str) -> None:
        _service().stop()

    def read_settings(self) -> dict:
        current = _service().settings().get("alarm") or {}
        return {k: current.get(k) for k in _ALARM_KEYS}

    def write_settings(self, changes: dict) -> None:
        _service().update_settings({"alarm": {k: int(v) for k, v in changes.items()}})

    def status_line(self) -> str:
        shown = _service().alarm.public()
        return {"disarmed": "Disarmed", "arming": "Arming…", "armed_away": "Armed (away)",
                "armed_home": "Armed (home)", "entry": "Door opened — entry delay",
                "triggered": "Alarm sounding"}.get(shown.get("state"), "—")

    def state(self) -> dict:
        return {"status": self.status_line()}
