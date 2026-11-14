"""The Car: Toyota control through Home Assistant, the car lights and its linked
devices — the whole Car page and CarPlay's car tab.

Protected. Off: the toyota_* tools and the car's "his yes" hook stop, /api/car
refuses (except the shared Face ID approver, which the door alarm, vault, security
advisor and Power approvals also use), and the phone hides the Car page and the
CarPlay car tab. Its linked devices fall back to their own Devices cards.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration, Setting


class Car(PowerIntegration):
    id = "car"
    name = "Car"
    icon = "car.fill"
    summary = "Your Camry: locks, climate and status, the car lights and CarPlay."
    protected = True
    toolsets = ("toyota",)
    route_prefixes = ("/api/car",)
    route_exempt = ("/api/car/approver", "/api/car/approvals")
    surfaces = ("ios.devices.car", "ios.bridge.car", "ios.carplay.car")
    links = (Link("ios", "car_page", "Open the Car page"),)
    settings = (
        Setting("HASS_URL", "Home Assistant URL", "text", default=""),
        Setting("HASS_TOKEN", "Home Assistant token", "secret"),
    )

    def read_settings(self) -> dict:
        from jarvis_power.stores import env_get
        return {"HASS_URL": env_get("HASS_URL") or "", "HASS_TOKEN": env_get("HASS_TOKEN") or ""}

    def write_settings(self, changes: dict) -> None:
        from jarvis_power.stores import env_set
        for key, value in changes.items():
            env_set(key, value or None)

    def status_line(self) -> str:
        from jarvis_power.stores import env_get
        return "Connected to Home Assistant" if env_get("HASS_TOKEN") else "Home Assistant not set up"
