"""Registering Power integrations' plugin hooks, gated on their switch."""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)
_installed_on = None


def install() -> None:
    """Add every integration's ``hooks()`` to the plugin manager. Idempotent per manager."""
    global _installed_on
    try:
        from jarviscopilot_cli.plugins import get_plugin_manager
        from jarvis_power import discovery
        from jarvis_power.gate import gated

        manager = get_plugin_manager()
        marker = id(getattr(manager, "_hooks", manager))
        if _installed_on == marker:
            return
        for p in discovery.integrations().values():
            for name, fn in (p.hooks() or {}).items():
                manager.register_hook(name, gated(p.id, fn))
        _installed_on = marker
    except Exception:
        logger.warning("power: hooks not installed", exc_info=True)
