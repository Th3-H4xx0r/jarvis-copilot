"""Frameless voice-orb popup window.

Reuses the webui voice UI (orb + realtime + transcript + Stop/Interrupt/Mute) by
loading /?mini=voice through the shared loopback PinnedProxy (see _proxy.py),
which forwards to the paired server over pinned TLS with the session cookie — so
the OS WebView never has to trust the self-signed cert directly.
"""
from __future__ import annotations

import logging
import webbrowser

from jc_client import credentials
from jc_client._mac_media import enable_microphone
# Re-exported for back-compat (callers/tests import these from voice_popup).
from jc_client._proxy import (  # noqa: F401
    PinnedProxy,
    build_upstream_head,
    _split_server_url,
)

logger = logging.getLogger(__name__)

_MINI_PATH = "/?mini=voice"


def _import_webview():
    """Return the pywebview module, or None if it isn't installed."""
    try:
        import webview  # type: ignore
        return webview
    except Exception:
        return None


def run_voice_popup() -> None:
    """Open the voice-orb popup (blocks until the window closes).

    No-ops if unpaired; falls back to the system browser if pywebview is
    unavailable."""
    creds = credentials.load()
    if not creds.paired:
        logger.error("voice-popup: client is not paired — run `jc-client pair` first")
        return

    proxy = PinnedProxy(creds.server_url, creds.cert_fingerprint, creds.cookie,
                        cf_client_id=creds.cf_client_id, cf_client_secret=creds.cf_client_secret)
    port = proxy.start()
    url = f"http://127.0.0.1:{port}{_MINI_PATH}"
    webview = _import_webview()
    try:
        if webview is None:
            logger.warning("pywebview unavailable; opening voice popup in default browser")
            webbrowser.open(url)
            proxy.wait()  # keep the proxy alive while the browser tab is open
        else:
            # Grant the embedded WebView microphone access before it loads
            # (pywebview doesn't do this itself). No-op off macOS.
            enable_microphone()
            # Native title bar → real close / minimize / zoom buttons, and the
            # window is freely movable (not pinned on-top "stuck to the screen").
            webview.create_window(
                "JARVIS",
                url,
                width=400,
                height=560,
                frameless=False,
                on_top=False,
                resizable=False,
            )
            webview.start(debug=False)
    finally:
        proxy.shutdown()
