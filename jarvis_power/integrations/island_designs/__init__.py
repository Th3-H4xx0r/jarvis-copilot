"""Dynamic Island designs: custom Live Activity designs you pin.

Off: no custom design is pushed (the island falls back to voice / coding as usual),
/api/island refuses, and the phone hides the designs screen.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration


class IslandDesigns(PowerIntegration):
    id = "island-designs"
    name = "Island designs"
    icon = "capsule.fill"
    summary = "Custom Dynamic Island designs you can pin."
    route_prefixes = ("/api/island",)
    surfaces = ("ios.more.island", "ios.deeplink.island", "ios.liveactivity.island_designs")
    links = (Link("ios", "island_designs", "Open Island designs"),)
