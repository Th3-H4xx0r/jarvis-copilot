"""The voice orb in its own window.

Shows the NATIVE Swift panel from `mac_app/` — the phone's voice stack built for
macOS — in a plain AppKit window. The same panel the menubar popover hosts, and
the same `VoiceStore` code the phone runs; only the frame differs.

Where that dylib is not available (nobody ran `mac_app/build.sh`, or we are not
on macOS) it falls back to what this used to be: the webui voice page at
/?mini=voice in a pywebview window.

Either way the server is reached through the shared loopback PinnedProxy (see
_proxy.py), which forwards to the paired server over pinned TLS with the session
cookie — so neither panel has to hold a credential or trust the self-signed cert
directly.
"""
from __future__ import annotations

import logging
import sys
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

# Built at import time on macOS only, so importing this module elsewhere (and in
# tests) stays free of PyObjC. Mirrors `mac_popover`.
#
# The Obj-C class name is namespaced because that namespace is PROCESS-WIDE and
# flat: a bare `_AppDelegate` is exactly what another library would also claim
# (pywebview builds one in this very process when we fall back to it), and the
# second registration of a name is an error, not a shadow.
_AppDelegate = None

if sys.platform == "darwin":  # pragma: no cover - needs a macOS run loop
    try:
        import AppKit as _AppKit
        import objc as _objc

        class JcVoiceWindowDelegate(_AppKit.NSObject):
            """Closing the window ends the process — it is all this process is for."""

            def applicationShouldTerminateAfterLastWindowClosed_(self, _app):
                return True

        _AppDelegate = JcVoiceWindowDelegate
    except Exception:  # pragma: no cover - PyObjC missing or a version we don't know
        _AppDelegate = None

_MINI_PATH = "/?mini=voice"
# Matches the menubar popover, so the panel lays out identically in both.
_WIDTH = 320
_HEIGHT = 438


def _run_native_window(origin: str) -> bool:
    """Show the Swift panel in an AppKit window; block until it closes.

    Returns False *without* having shown anything when the native panel is not
    available, so the caller can fall back. A failure once the window is up is
    not a fallback — the user has already seen it — and comes back as True.
    """
    from jc_client.mac_popover import _voice_panel_class

    cls = _voice_panel_class()
    if cls is None:
        return False
    try:
        import AppKit

        from jc_client._mac_media import prepare_microphone
        prepare_microphone()

        panel = cls.makeViewControllerWithBaseURL_(origin)
        if panel is None:
            logger.warning("voice-popup: the native panel refused %s", origin)
            return False

        app = AppKit.NSApplication.sharedApplication()
        app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
        style = (AppKit.NSWindowStyleMaskTitled
                 | AppKit.NSWindowStyleMaskClosable
                 | AppKit.NSWindowStyleMaskMiniaturizable)
        window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            AppKit.NSMakeRect(0, 0, _WIDTH, _HEIGHT), style,
            AppKit.NSBackingStoreBuffered, False)
        window.setTitle_("JARVIS")
        window.setContentViewController_(panel)
        # After the controller, not before: assigning one re-sizes the window to
        # whatever the hosting controller asks for, which for a SwiftUI view with
        # no fixed size is its MINIMUM. The window's size is ours to choose.
        window.setContentSize_(AppKit.NSMakeSize(_WIDTH, _HEIGHT))
        window.setReleasedWhenClosed_(False)
        window.center()
        window.makeKeyAndOrderFront_(None)
        app.activateIgnoringOtherApps_(True)

        delegate = _AppDelegate.alloc().init() if _AppDelegate is not None else None
        if delegate is not None:
            app.setDelegate_(delegate)
        try:
            app.run()
        finally:
            # This process exists only for the window, but the turn machine holds
            # the mic and a socket — let it put them down before we go.
            try:
                cls.stopEverything()
            except Exception:
                logger.debug("voice-popup: the native panel would not stop", exc_info=True)
        return True
    except Exception:
        logger.exception("voice-popup: the native window failed")
        return False


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
                        cf_client_id=creds.cf_client_id, cf_client_secret=creds.cf_client_secret,
                        lan_url=creds.lan_url)
    port = proxy.start()
    origin = f"http://127.0.0.1:{port}"
    url = origin + _MINI_PATH
    try:
        if _run_native_window(origin):
            return
        webview = _import_webview()
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
