"""Steel cloud browser plugin — bundled, auto-loaded.

Same layout as ``plugins/browser/browserbase/``: ``provider.py`` holds the
provider class; ``register`` instantiates and registers it.
"""

from __future__ import annotations

from plugins.browser.steel.provider import SteelBrowserProvider


def register(ctx) -> None:
    """Register the Steel provider with the plugin context."""
    ctx.register_browser_provider(SteelBrowserProvider())
