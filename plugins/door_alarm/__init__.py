"""Door Alarm: Pranav's PHYSEN Smart Life door-sensor hub as a Jarvis device with a security alarm.

The alarm runs in the webui (``service.DoorService``, started at boot; routes in
``webui/api/door_routes.py``). Hub reports come from an ESP32 at home speaking Tuya's LAN protocol
(bridge ``event`` frames) and from Tuya's cloud message service as a fallback. Disarm/silence need
Face ID on the iPhone (the car's Secure Enclave key, ``jarvis-home`` messages).
"""
from __future__ import annotations

from plugins.door_alarm.tools import TOOLS, available


def register(ctx) -> None:
    for name, schema, handler, emoji in TOOLS:
        ctx.register_tool(name=name, toolset="door_alarm", schema=schema, handler=handler,
                          check_fn=available, emoji=emoji)
