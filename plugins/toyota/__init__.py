"""Toyota connected services for Pranav's car — bundled, auto-loaded.

His Home Assistant runs the Toyota (North America) integration (orienw/ha-toyota-na, audited and
pinned at v2.10.1); these tools and the Car page's /api/car routes talk only to Home Assistant,
never to Toyota. Sign-in happens on the iPhone Car page.
"""
from __future__ import annotations

from plugins.toyota.tools import TOOLS, available


def register(ctx) -> None:
    for name, schema, handler, emoji in TOOLS:
        ctx.register_tool(name=name, toolset="toyota", schema=schema, handler=handler,
                          check_fn=available, emoji=emoji)
