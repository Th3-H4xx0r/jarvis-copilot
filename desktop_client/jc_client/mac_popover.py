"""Menu-bar popover hosting the voice orb (macOS only).

The tray is pystray, and a pystray menu can only hold text items — so the orb
cannot live inside it. What it *does* give us is a real ``NSStatusItem``, which
is all a native popover needs. This attaches one to it:

    left-click   → the orb + voice UI, hanging off the menubar icon
    right-click  → the menu pystray already builds, unchanged

pystray sets the status item's ``menu``, and AppKit then opens that menu on
*any* mouse-down and never calls the button's action — so the menu is unhooked
from the item and kept aside, and both clicks are routed here instead. It is put
back for the moment the menu is actually shown.

The popover's content is the same ``/?mini=voice`` page the separate window uses,
loaded through the shared loopback :class:`PinnedProxy` so the WebView never has
to trust the gateway's self-signed cert. "Open in Window" hands off to the
existing standalone popup, which is untouched.

Everything here is best-effort: if PyObjC, WebKit or pystray's internals aren't
what we expect, :func:`install` returns None and the tray keeps its old
behaviour (menu on any click, voice orb as a separate window).
"""
from __future__ import annotations

import logging
import sys
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# Popover size. Matches the standalone window so the page lays out identically.
_WIDTH = 400
_HEIGHT = 560
# Native strip under the web view carrying "Open in Window".
_FOOTER_H = 34

_MINI_PATH = "/?mini=voice"


def _const(module, *names, default=None):
    """First constant that exists under any of `names` — PyObjC renamed a lot of
    AppKit constants between versions, and we support both spellings."""
    for name in names:
        value = getattr(module, name, None)
        if value is not None:
            return value
    return default


class MenuBarVoicePopover:
    """Owns the NSPopover, its WKWebView and the loopback proxy behind it."""

    def __init__(self, icon, on_open_window: Callable[[], None]):
        self._icon = icon
        self._on_open_window = on_open_window
        self._popover = None
        self._webview = None
        self._proxy = None
        self._url: Optional[str] = None
        # The menu pystray built, held here while the status item has none.
        self._menu = None
        self._delegate = None
        self._webview_delegate = None
        self._status_item = None
        self._button = None

    # ── install ──────────────────────────────────────────────────────

    def install(self) -> bool:
        """Take over the status item's clicks. False if anything is missing."""
        try:
            import AppKit  # noqa: F401
            import WebKit  # noqa: F401
            import objc  # noqa: F401
        except Exception as exc:
            logger.info("voice popover unavailable (no PyObjC/WebKit): %s", exc)
            return False
        if _ClickDelegate is None:
            logger.info("voice popover unavailable: Obj-C glue did not load")
            return False

        import AppKit
        status_item = getattr(self._icon, "_status_item", None)
        button = status_item.button() if status_item is not None else None
        if button is None:
            logger.info("voice popover unavailable: pystray exposed no status item")
            return False
        self._status_item = status_item
        self._button = button

        # A menubar app should be an accessory: a regular app owns a Space and a
        # Dock tile, and activating it drags the user to that Space. Accessory
        # apps activate in place, on the display they were clicked on.
        try:
            policy = _const(AppKit, "NSApplicationActivationPolicyAccessory", default=1)
            AppKit.NSApp.setActivationPolicy_(policy)
        except Exception as exc:
            logger.debug("voice popover: could not become an accessory app: %s", exc)

        self._delegate = _ClickDelegate.alloc().init()
        self._delegate.owner = self
        button.setTarget_(self._delegate)
        button.setAction_(b"statusClick:")

        left = _const(AppKit, "NSEventMaskLeftMouseDown", "NSLeftMouseDownMask", default=1 << 1)
        right = _const(AppKit, "NSEventMaskRightMouseDown", "NSRightMouseDownMask", default=1 << 3)
        button.sendActionOn_(left | right)

        # pystray re-attaches the menu on every refresh; keep it detached so the
        # button action keeps firing, and remember the menu for right-clicks.
        self._steal_menu()
        original = self._icon._update_menu

        def _update_menu_then_detach(*args, **kwargs):
            result = original(*args, **kwargs)
            self._steal_menu()
            return result

        self._icon._update_menu = _update_menu_then_detach
        logger.info("voice popover installed on the menubar item")
        return True

    def _steal_menu(self) -> None:
        """Hold pystray's menu aside and leave the status item without one."""
        try:
            menu = self._status_item.menu()
            if menu is not None:
                self._menu = menu
                self._status_item.setMenu_(None)
        except Exception as exc:
            logger.debug("voice popover: could not detach the menu: %s", exc)

    # ── clicks ───────────────────────────────────────────────────────

    def handle_click(self) -> None:
        """Route one status-item click: right opens the menu, left the orb."""
        try:
            if self._is_secondary_click():
                self.show_menu()
            else:
                self.toggle()
        except Exception:
            logger.exception("voice popover: click handling failed")

    def _is_secondary_click(self) -> bool:
        import AppKit
        event = AppKit.NSApp.currentEvent()
        if event is None:
            return False
        right_down = _const(AppKit, "NSEventTypeRightMouseDown", "NSRightMouseDown", default=3)
        if event.type() == right_down:
            return True
        # Control-click is a right-click everywhere else on macOS; be consistent.
        control = _const(AppKit, "NSEventModifierFlagControl", "NSControlKeyMask", default=1 << 18)
        return bool(event.modifierFlags() & control)

    def show_menu(self) -> None:
        """Put the menu back just long enough for AppKit to track it."""
        if self._menu is None:
            return
        self.close()
        self._status_item.setMenu_(self._menu)
        try:
            self._button.performClick_(None)   # blocks while the menu is open
        finally:
            self._status_item.setMenu_(None)

    def toggle(self) -> None:
        popover = self._ensure_popover()
        if popover is None:
            # No web view to show — fall back to the standalone window rather
            # than doing nothing at all.
            self._on_open_window()
            return
        if popover.isShown():
            popover.performClose_(None)
            return
        import AppKit
        edge = _const(AppKit, "NSRectEdgeMinY", "NSMinYEdge", default=1)
        # Show FIRST, activate after. Activating a regular app pulls the system
        # to whichever Space that app lives on — which, from a full-screen window
        # on another display, is how the panel ended up opening on the wrong
        # monitor. Showing first anchors it to the status button that was
        # actually clicked.
        popover.showRelativeToRect_ofView_preferredEdge_(self._button.bounds(), self._button, edge)
        self._pin_to_current_space(popover)
        AppKit.NSApp.activateIgnoringOtherApps_(True)
        # The page only starts capturing once it has key focus.
        try:
            self._webview.window().makeFirstResponder_(self._webview)
        except Exception:
            pass

    def _pin_to_current_space(self, popover) -> None:
        """Let the panel draw on whatever Space is in front, full-screen included.

        Without this the popover's window belongs to the app's own Space, so
        invoking it from a full-screen window elsewhere either yanks you to
        another display or leaves the panel behind on it."""
        try:
            import AppKit
            window = popover.contentViewController().view().window()
            if window is None:
                return
            window.setCollectionBehavior_(
                _const(AppKit, "NSWindowCollectionBehaviorCanJoinAllSpaces", default=1 << 0)
                | _const(AppKit, "NSWindowCollectionBehaviorFullScreenAuxiliary", default=1 << 8)
                | _const(AppKit, "NSWindowCollectionBehaviorTransient", default=1 << 3))
        except Exception as exc:
            logger.debug("voice popover: could not pin the panel to this space: %s", exc)

    def close(self) -> None:
        try:
            if self._popover is not None and self._popover.isShown():
                self._popover.performClose_(None)
        except Exception:
            pass

    # ── content ──────────────────────────────────────────────────────

    def _ensure_popover(self):
        if self._popover is not None:
            return self._popover
        url = self._ensure_url()
        if url is None:
            return None
        try:
            self._popover = self._build_popover(url)
        except Exception:
            logger.exception("voice popover: could not build the panel")
            return None
        return self._popover

    def _ensure_url(self) -> Optional[str]:
        """Start the loopback proxy once and return the page URL."""
        if self._url is not None:
            return self._url
        from jc_client import credentials
        from jc_client._proxy import PinnedProxy

        creds = credentials.load()
        if not creds.paired:
            logger.info("voice popover: not paired yet")
            return None
        try:
            proxy = PinnedProxy(
                creds.server_url, creds.cert_fingerprint, creds.cookie,
                cf_client_id=creds.cf_client_id, cf_client_secret=creds.cf_client_secret,
                lan_url=creds.lan_url,
            )
            port = proxy.start()
        except Exception:
            logger.exception("voice popover: loopback proxy failed to start")
            return None
        self._proxy = proxy
        self._url = f"http://127.0.0.1:{port}{_MINI_PATH}"
        return self._url

    def _build_popover(self, url: str):
        import AppKit
        import WebKit
        from Foundation import NSURL, NSURLRequest

        from jc_client._mac_media import prepare_microphone
        prepare_microphone()

        config = WebKit.WKWebViewConfiguration.alloc().init()
        try:
            # TTS has to play without a click, and capture must not need a
            # gesture the popover never sees.
            config.setMediaTypesRequiringUserActionForPlayback_(0)
        except Exception:
            pass

        total_h = _HEIGHT + _FOOTER_H
        container = AppKit.NSView.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, _WIDTH, total_h))

        webview = WebKit.WKWebView.alloc().initWithFrame_configuration_(
            AppKit.NSMakeRect(0, _FOOTER_H, _WIDTH, _HEIGHT), config)
        webview.setAutoresizingMask_(
            _const(AppKit, "NSViewWidthSizable", default=2)
            | _const(AppKit, "NSViewHeightSizable", default=16))
        if _WebViewDelegate is not None:
            self._webview_delegate = _WebViewDelegate.alloc().init()
            webview.setUIDelegate_(self._webview_delegate)
        try:
            # The page is dark; stop a white flash on every open.
            webview.setValue_forKey_(False, "drawsBackground")
        except Exception:
            pass
        webview.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(url)))
        container.addSubview_(webview)
        self._webview = webview

        button = AppKit.NSButton.alloc().initWithFrame_(
            AppKit.NSMakeRect(_WIDTH - 150, 6, 142, 22))
        button.setTitle_("Open in Window")
        button.setBezelStyle_(_const(AppKit, "NSBezelStyleRounded",
                                     "NSRoundedBezelStyle", default=1))
        button.setControlSize_(_const(AppKit, "NSControlSizeSmall", default=1))
        button.setFont_(AppKit.NSFont.systemFontOfSize_(11))
        button.setTarget_(self._delegate)
        button.setAction_(b"openInWindow:")
        button.setAutoresizingMask_(_const(AppKit, "NSViewMinXMargin", default=1)
                                    | _const(AppKit, "NSViewMaxYMargin", default=32))
        container.addSubview_(button)

        controller = AppKit.NSViewController.alloc().init()
        controller.setView_(container)

        popover = AppKit.NSPopover.alloc().init()
        popover.setContentViewController_(controller)
        popover.setContentSize_(AppKit.NSMakeSize(_WIDTH, total_h))
        # Transient: clicking anywhere else dismisses it, like every other
        # menubar panel on the system.
        popover.setBehavior_(_const(AppKit, "NSPopoverBehaviorTransient", default=1))
        popover.setAnimates_(True)
        return popover

    # ── teardown ─────────────────────────────────────────────────────

    def shutdown(self) -> None:
        self.close()
        if self._proxy is not None:
            try:
                self._proxy.shutdown()
            except Exception:
                pass
            self._proxy = None

    def open_in_window(self) -> None:
        """Hand off to the standalone popup and dismiss the panel."""
        self.close()
        try:
            self._on_open_window()
        except Exception:
            logger.exception("voice popover: opening the separate window failed")


def install(icon, on_open_window: Callable[[], None]) -> Optional[MenuBarVoicePopover]:
    """Attach the popover to a running pystray icon. None when unsupported."""
    if sys.platform != "darwin":
        return None
    popover = MenuBarVoicePopover(icon, on_open_window)
    try:
        return popover if popover.install() else None
    except Exception:
        logger.exception("voice popover: install failed")
        return None


# ── Objective-C glue ─────────────────────────────────────────────────
# Built at import time on macOS only, so importing this module elsewhere (and in
# tests) stays free of PyObjC.

_ClickDelegate = None
_WebViewDelegate = None
# Decision blocks we could not call; held so WebKit never releases them. See
# `_grant` — releasing an uncalled one aborts the process.
_UNANSWERED: list = []

if sys.platform == "darwin":  # pragma: no cover - needs a macOS run loop
    try:
        import AppKit as _AppKit
        import objc as _objc

        from jc_client._mac_media import _SELECTOR, _SIGNATURE, _WK_PERMISSION_GRANT

        # PyObjC works out how to call a block from the block's own descriptor,
        # and WebKit hands this one over without that signature — so calling it
        # failed with "cannot call block without a signature". This is what
        # describes it up front instead of relying on introspection: argument 6
        # (0 self, 1 _cmd, 2 webView, 3 origin, 4 frame, 5 type, 6 handler) is
        # void(WKPermissionDecision).
        try:
            _objc.registerMetaDataForSelector(b"NSObject", _SELECTOR, {
                "arguments": {
                    6: {"callable": {"retval": {"type": b"v"},
                                     "arguments": {0: {"type": b"^v"}, 1: {"type": b"q"}}}},
                },
            })
        except Exception as _meta_exc:
            logger.debug("voice popover: block metadata not registered: %s", _meta_exc)

        class _ClickDelegate(_AppKit.NSObject):  # noqa: F811
            """Target for the status-item button and the footer button."""

            owner = None

            def statusClick_(self, _sender):
                if self.owner is not None:
                    self.owner.handle_click()

            def openInWindow_(self, _sender):
                if self.owner is not None:
                    self.owner.open_in_window()

        class _WebViewDelegate(_AppKit.NSObject):  # noqa: F811
            """Grants the page microphone access.

            WKWebView denies capture unless its UI delegate answers, and the
            origin here is our own loopback proxy, so granting is safe.
            """

        def _grant(self, _webview, _origin, _frame, _type, decision_handler):
            # Nothing may escape from here into Obj-C: WebKit calls this from a
            # C++ frame with no handler, so a raised exception is an abort.
            try:
                decision_handler(_WK_PERMISSION_GRANT)
                return
            except Exception:
                logger.exception("voice popover: granting microphone access failed")
            # WebKit also aborts when a decision block is RELEASED without having
            # been called ("CompletionHandlerCallChecker"), so swallowing the
            # failure is not enough — holding a reference keeps that check from
            # ever running. The request simply goes unanswered: no microphone in
            # the panel, but a tray that is still alive.
            _UNANSWERED.append(decision_handler)

        _objc.classAddMethods(_WebViewDelegate, [
            _objc.selector(_grant, selector=_SELECTOR, signature=_SIGNATURE),
        ])
    except Exception as _exc:  # pragma: no cover - PyObjC missing/incompatible
        logger.debug("voice popover: Obj-C glue unavailable: %s", _exc)
        _ClickDelegate = None
        _WebViewDelegate = None
