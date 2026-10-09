"""Toyota connected services for Pranav's car — bundled, auto-loaded.

His Home Assistant runs the Toyota (North America) integration (orienw/ha-toyota-na, audited and
pinned at v2.10.1); these tools and the Car page's /api/car routes talk only to Home Assistant,
never to Toyota. Sign-in happens on the iPhone Car page.
"""
from __future__ import annotations

# Aliased: plain `guard` here would shadow the plugins.toyota.guard module.
from plugins.toyota.guard import guard as car_guard
from plugins.toyota.tools import TOOLS, available


def register(ctx) -> None:
    for name, schema, handler, emoji in TOOLS:
        ctx.register_tool(name=name, toolset="toyota", schema=schema, handler=handler,
                          check_fn=available, emoji=emoji)
    # The general Home Assistant tool must not unlock or start the car behind toyota_command.
    from tools.homeassistant_tool import SERVICE_GUARDS

    if car_guard not in SERVICE_GUARDS:
        SERVICE_GUARDS.append(car_guard)
