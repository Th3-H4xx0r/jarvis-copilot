"""Local web extraction plugin — bundled, auto-loaded.

Reads pages on this machine with no API key: Scrapling's fast fetcher plus
trafilatura, then the headless browser for JavaScript pages, then Scrapling's
stealth browser for bot-challenged sites. Extract only (pair it with any search
provider). Needs the optional ``web-local`` extra; gated via
:meth:`LocalWebProvider.is_available`.
"""

from __future__ import annotations

from plugins.web.local.provider import LocalWebProvider


def register(ctx) -> None:
    """Register the local extract provider with the plugin context."""
    ctx.register_web_search_provider(LocalWebProvider())
