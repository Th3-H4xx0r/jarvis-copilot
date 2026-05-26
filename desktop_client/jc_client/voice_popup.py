"""Frameless, always-on-top, draggable voice-orb popup window.

Reuses the webui voice UI (orb + realtime + transcript + Stop/Interrupt/Mute)
by loading /?mini=voice, authenticated via /api/auth/handoff using the session
cookie the client already holds. Launched as its own process (see the cli
``voice-popup`` subcommand) so it doesn't fight the tray for the macOS main
run loop.
"""
from __future__ import annotations

import logging
import webbrowser
from urllib.parse import quote

from jc_client import credentials

logger = logging.getLogger(__name__)

_MINI_NEXT = "/?mini=voice"


def build_popup_url(server_url: str, cookie: str) -> str:
    """Compose the handoff URL that boots the webview straight into mini voice.

    Both the cookie value and the `next` path are percent-encoded so reserved
    characters (``&``, ``/``, ``?``) can't break out of their query parameter.
    """
    base = server_url.rstrip("/")
    return (f"{base}/api/auth/handoff"
            f"?session={quote(cookie, safe='')}"
            f"&next={quote(_MINI_NEXT, safe='')}")


def _import_webview():
    """Return the pywebview module, or None if it isn't installed."""
    try:
        import webview  # type: ignore
        return webview
    except Exception:
        return None


def run_voice_popup() -> None:
    """Open the voice-orb popup window (blocks until the window closes).

    Falls back to the system browser if pywebview is unavailable, and no-ops if
    the client isn't paired yet (no session to hand off)."""
    creds = credentials.load()
    if not creds.paired:
        logger.error("voice-popup: client is not paired — run `jc-client pair` first")
        return
    url = build_popup_url(creds.server_url, creds.cookie)
    webview = _import_webview()
    if webview is None:
        logger.warning("pywebview unavailable; opening voice popup in default browser")
        webbrowser.open(url)
        return
    # The client pinned the gateway's self-signed cert at pair time; pywebview
    # uses the OS webview, which trusts the system store the pairing step
    # populated. Frameless + on_top + easy_drag gives the small draggable HUD.
    webview.create_window(
        "JARVIS",
        url,
        width=380,
        height=520,
        frameless=True,
        on_top=True,
        easy_drag=True,
        resizable=False,
    )
    webview.start(debug=False)
