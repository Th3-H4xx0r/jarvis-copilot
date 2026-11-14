"""Widgets: Home and Lock Screen widgets Jarvis designs from blocks.

Off: /api/widgets refuses, the phone stops its widget data hub and hides the
Widgets settings row; widgets already on the Home Screen show that they're off.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration


class Widgets(PowerIntegration):
    id = "widgets"
    name = "Widgets"
    icon = "square.grid.2x2.fill"
    summary = "Home and Lock Screen widgets Jarvis designs for you."
    route_prefixes = ("/api/widgets",)
    surfaces = ("ios.settings.widgets", "ios.bg.widgets", "ios.widget.designs")
    links = (Link("ios", "widgets", "Open Widgets"),)
