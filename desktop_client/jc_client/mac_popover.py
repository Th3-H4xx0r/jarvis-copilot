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

The popover's content is the NATIVE Swift panel from ``mac_app/`` — the phone's
own voice stack, built for macOS — loaded out of a dylib. It talks to the server
through the shared loopback :class:`PinnedProxy`, which holds the pinned cert and
the session cookie, so the Swift side needs no credentials of its own. When the
dylib is missing (nobody has run ``mac_app/build.sh``) it falls back to the
``/?mini=voice`` page in a WebView, which is what this used to be. "Open in
Window" hands off to the existing standalone popup, which is untouched.

Everything here is best-effort: if PyObjC, WebKit or pystray's internals aren't
what we expect, :func:`install` returns None and the tray keeps its old
behaviour (menu on any click, voice orb as a separate window).
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# `None` is a real answer here ("looked, not there"), so the not-yet-looked state
# needs a value of its own.
_UNSET = object()
_panel_class = _UNSET
# Why the last look failed, for `voice_panel_health` to report. Kept because the
# fallback is silent by design: the user gets the web panel either way, so the
# only way "the native panel is not running" ever reaches them is if something
# asks.
_panel_error: Optional[str] = None

# Popover size. Matches the standalone window so the page lays out identically.
_WIDTH = 400
_HEIGHT = 560
# Native strip under the web view carrying "Open in Window".
_FOOTER_H = 34

_MINI_PATH = "/?mini=voice"

# Row metrics. The device rows are drawn by hand (see `_RowView`) rather than
# handed to AppKit as text: a menu item lays its text out after its image, so a
# status dot placed with a tab stop moves with whatever is to its left and never
# lines up between rows. Drawing puts it at a fixed distance from the row's
# trailing edge, which is the only way it sits in a true column.
_ICON_PT = 27.0
_ROW_WIDTH = 340.0
_ROW_HEIGHT = 34.0
_LEFT_INSET = 14.0
_GAP = 9.0
_DOT_PT = 8.0
_DOT_RIGHT_INSET = 16.0
# Gap between a row's detail ("Connected", "-87 dBm") and its status dot.
_DETAIL_GAP = 10.0
_HEADER_HEIGHT = 24.0
_HEADER_INSET = 11.0


def _voice_panel_class():
    """The Swift panel's class, or None when the dylib isn't there.

    ``ctypes.CDLL`` is the whole load: a dylib registers its ``@objc`` classes
    with the Obj-C runtime as it loads, so the class is then reachable by name.
    Cached because dlopen is idempotent but the lookup is not free.
    """
    global _panel_class, _panel_error
    if _panel_class is not _UNSET:
        return _panel_class
    _panel_class = None
    # Checked before anything is imported, so "never built" is answered the same
    # way on a machine without PyObjC as on one with it.
    dylib = _dylib_path()
    if not dylib.exists():
        _panel_error = f"{dylib.name} is not in this checkout — run mac_app/build.sh"
        logger.info("voice popover: no %s — run mac_app/build.sh; using the web panel",
                    dylib.name)
        return None
    try:
        import ctypes

        import objc

        ctypes.CDLL(str(dylib))
        cls = objc.lookUpClass("JarvisVoicePanel")
    except Exception as exc:
        # Typically PyObjC missing, or a dylib built for another architecture —
        # ctypes says which, and it is the whole diagnosis, so keep the text.
        _panel_error = str(exc)
        logger.info("voice popover: native panel unavailable (%s); using the web panel", exc)
        return None
    # A missing shader draws an empty rectangle where the orb should be and
    # reports nothing, so say it here rather than leave it to be noticed.
    try:
        if not cls.orbShaderAvailable():
            logger.warning("voice popover: the orb's shader bundle is missing "
                           "next to the dylib — re-run mac_app/build.sh")
    except Exception:
        pass
    _panel_class = cls
    return cls


def _dylib_path() -> Path:
    return Path(__file__).with_name("assets") / "libJarvisVoiceUI.dylib"


def voice_panel_health() -> tuple[bool, str]:
    """Is the native voice panel usable on this machine? (ok, one line to print)

    `jc-client status` and `jc-client update` both show this. Worth surfacing
    because every failure here is a SILENT downgrade to the web panel: voice
    still works, so nothing complains, and the only symptom is that the Mac
    stopped looking like the phone.
    """
    if sys.platform != "darwin":
        return False, "n/a (macOS only)"
    dylib = _dylib_path()
    if not dylib.exists():
        return False, f"web panel — {dylib.name} is missing (run mac_app/build.sh)"
    if _voice_panel_class() is None:
        return False, f"web panel — {dylib.name} would not load: {_panel_error}"
    try:
        if not _panel_class.orbShaderAvailable():
            return True, ("native panel, but the orb has no shader "
                          "(re-run mac_app/build.sh)")
    except Exception:  # pragma: no cover - an older dylib without the check
        pass
    return True, "native panel"


def _kind_symbol(kind: str, name: str = "") -> str:
    from jc_client.device_roster import kind_symbol
    return kind_symbol(kind, name)


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
        # Exactly one of these is live: the native Swift panel, or the WebView
        # that stands in when its dylib was never built.
        self._panel = None
        self._webview = None
        self._proxy = None
        self._url: Optional[str] = None
        # The menu pystray built, held here while the status item has none.
        self._menu = None
        self._delegate = None
        self._webview_delegate = None
        self._status_item = None
        self._button = None
        # Set by the tray: the device rows currently in the menu, so each item
        # can be given the right picture.
        self.rows_for_icons = None
        self._image_cache: dict = {}

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
                self._style_rows(menu)
        except Exception as exc:
            logger.debug("voice popover: could not detach the menu: %s", exc)

    # ── device pictures ──────────────────────────────────────────────

    def _style_rows(self, menu) -> None:
        """Dress the device rows to look like a system menu.

        pystray can only put plain text in a menu, but the items it builds are
        ordinary NSMenuItems — so each row is restyled here, matched by its
        plain title: the device's picture on the left, its name in the menu
        font, the detail in a smaller secondary colour, and a status dot drawn
        at the trailing edge the way the Wi-Fi menu puts a lock there. Section
        headings become real section headers.
        """
        rows = self.rows_for_icons() if self.rows_for_icons else []
        if not rows:
            return
        by_title = {row.title: row for row in rows}
        try:
            for index in range(menu.numberOfItems()):
                item = menu.itemAtIndex_(index)
                row = by_title.get(str(item.title()))
                if row is None:
                    continue
                if row.header:
                    self._style_header(item, row)
                else:
                    self._style_device(item, row)
        except Exception as exc:
            logger.debug("voice popover: could not style the menu: %s", exc)

    def _style_header(self, item, row) -> None:
        """A section heading, drawn at the menu's own left margin.

        As a titled item it would start after the image gutter, indented under
        the rows it heads; drawn, it sits where the system puts "Known Networks".
        """
        if _RowView is None:
            return
        view = _RowView.alloc().initWithFrame_(
            _AppKit.NSMakeRect(0, 0, _ROW_WIDTH, _HEADER_HEIGHT))
        view.row = row
        view.image = None
        item.setImage_(None)
        item.setView_(view)

    def _style_device(self, item, row) -> None:
        """Hand the row to a view that draws itself, so every part is placed.

        These rows are never clickable, so a custom view costs nothing in
        behaviour — and it is the only way the pictures all render at one size
        and the status dots share a column.
        """
        if _RowView is None:
            return
        view = _RowView.alloc().initWithFrame_(
            _AppKit.NSMakeRect(0, 0, _ROW_WIDTH, _ROW_HEIGHT))
        view.row = row
        view.image = self._image_for(row)
        item.setImage_(None)
        item.setView_(view)

    def _image_for(self, row):
        """One row's picture, cached — the menu rebuilds every couple of seconds."""
        symbol = _kind_symbol(row.kind, row.name)
        key = row.wearable or f"symbol:{symbol}"
        if key in self._image_cache:
            return self._image_cache[key]
        image = self._render_wearable(row.wearable) if row.wearable else self._symbol(symbol)
        self._image_cache[key] = image
        return image

    def _render_wearable(self, wearable: str):  # noqa: D401
        """The PNG rendered from the device's own 3D model in the iOS app."""
        import AppKit
        from pathlib import Path

        path = Path(__file__).with_name("assets") / f"icon-{wearable}.png"
        if not path.exists():
            # The ESP32 has no 3D model — it is a board, so a board glyph.
            return self._symbol("cpu")
        image = AppKit.NSImage.alloc().initWithContentsOfFile_(str(path))
        if image is None:
            return None
        image.setSize_(AppKit.NSMakeSize(_ICON_PT, _ICON_PT))
        return image

    def _tinted(self, image, colour):
        """A template symbol drawn by hand loses the tint AppKit would give it."""
        import AppKit

        out = image.copy()
        out.setSize_(AppKit.NSMakeSize(_ICON_PT, _ICON_PT))
        out.lockFocus()
        colour.set()
        AppKit.NSRectFillUsingOperation(
            AppKit.NSMakeRect(0, 0, _ICON_PT, _ICON_PT),
            _const(AppKit, "NSCompositingOperationSourceAtop", default=5))
        out.unlockFocus()
        out.setTemplate_(False)
        return out

    def _symbol(self, name: str):
        import AppKit

        try:
            image = AppKit.NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
        except Exception:
            image = None
        if image is None:
            return None
        image.setSize_(AppKit.NSMakeSize(_ICON_PT, _ICON_PT))
        image.setTemplate_(True)
        # Drawn by hand, so the menu's own tinting no longer applies.
        return self._tinted(image, AppKit.NSColor.labelColor())

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
        # Neither panel starts capturing until it has key focus.
        view = self._panel.view() if self._panel is not None else self._webview
        try:
            view.window().makeFirstResponder_(view)
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
        """Start the loopback proxy once and return its origin.

        The origin, not a page URL: the native panel wants the API base to point
        `JarvisAPI` at, and the web fallback appends `_MINI_PATH` itself.
        """
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
        self._url = f"http://127.0.0.1:{port}"
        return self._url

    def _build_popover(self, origin: str):
        import AppKit

        from jc_client._mac_media import prepare_microphone
        prepare_microphone()

        total_h = _HEIGHT + _FOOTER_H
        container = AppKit.NSView.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, _WIDTH, total_h))
        frame = AppKit.NSMakeRect(0, _FOOTER_H, _WIDTH, _HEIGHT)
        resize = (_const(AppKit, "NSViewWidthSizable", default=2)
                  | _const(AppKit, "NSViewHeightSizable", default=16))

        self._panel = self._native_panel(origin, frame, resize)
        content = self._panel.view() if self._panel is not None \
            else self._web_view(origin, frame, resize)
        container.addSubview_(content)

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
        if self._panel is not None:
            # Containment, not just a subview: it is what forwards "the popover
            # opened/closed" down to the panel, and SwiftUI's `onDisappear` is
            # what stops the orb's 60 fps ticker when the panel is put away.
            controller.addChildViewController_(self._panel)

        popover = AppKit.NSPopover.alloc().init()
        popover.setContentViewController_(controller)
        popover.setContentSize_(AppKit.NSMakeSize(_WIDTH, total_h))
        # Transient: clicking anywhere else dismisses it, like every other
        # menubar panel on the system.
        popover.setBehavior_(_const(AppKit, "NSPopoverBehaviorTransient", default=1))
        popover.setAnimates_(True)
        return popover

    def _native_panel(self, origin: str, frame, resize):
        """The Swift voice panel's view controller, or None if it isn't there."""
        cls = _voice_panel_class()
        if cls is None:
            return None
        try:
            panel = cls.makeViewControllerWithBaseURL_(origin)
        except Exception:
            logger.exception("voice popover: the native panel would not build")
            return None
        if panel is None:
            logger.warning("voice popover: the native panel refused %s", origin)
            return None
        panel.view().setFrame_(frame)
        panel.view().setAutoresizingMask_(resize)
        return panel

    def _web_view(self, origin: str, frame, resize):
        """The old content: the `/?mini=voice` page in a WebView."""
        import AppKit  # noqa: F401
        import WebKit
        from Foundation import NSURL, NSURLRequest

        config = WebKit.WKWebViewConfiguration.alloc().init()
        try:
            # TTS has to play without a click, and capture must not need a
            # gesture the popover never sees.
            config.setMediaTypesRequiringUserActionForPlayback_(0)
        except Exception:
            pass
        webview = WebKit.WKWebView.alloc().initWithFrame_configuration_(frame, config)
        webview.setAutoresizingMask_(resize)
        if _WebViewDelegate is not None:
            self._webview_delegate = _WebViewDelegate.alloc().init()
            webview.setUIDelegate_(self._webview_delegate)
        try:
            # The page is dark; stop a white flash on every open.
            webview.setValue_forKey_(False, "drawsBackground")
        except Exception:
            pass
        url = NSURL.URLWithString_(origin + _MINI_PATH)
        webview.loadRequest_(NSURLRequest.requestWithURL_(url))
        self._webview = webview
        return webview

    # ── teardown ─────────────────────────────────────────────────────

    def shutdown(self) -> None:
        self.close()
        if self._panel is not None:
            # Closing the popover only hides it — a conversation would keep the
            # mic and the socket for as long as the tray process lives.
            try:
                # The class, not the controller: the session is process-wide, so
                # stopping it is a class method (`self._panel` is the SwiftUI
                # hosting controller the class handed back).
                _voice_panel_class().stopEverything()
            except Exception:
                logger.debug("voice popover: the native panel would not stop", exc_info=True)
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
_RowView = None
_AppKit = None
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

        class _RowView(_AppKit.NSView):
            """One device or heading, drawn rather than described.

            A menu item lays its text out after its image, so anything pinned to
            the trailing edge with a tab stop shifts with whatever precedes it —
            which is why the status dots never shared a column. Drawing places
            every part against the row's own bounds instead. These rows are not
            clickable, so nothing of a menu item's behaviour is given up.
            """

            row = None
            image = None

            def drawRect_(self, _dirty):
                bounds = self.bounds()
                if self.row is None:
                    return
                if getattr(self.row, "header", False):
                    self._draw_header(bounds)
                else:
                    self._draw_device(bounds)

            def _draw_header(self, bounds):
                text = _AppKit.NSAttributedString.alloc().initWithString_attributes_(
                    str(self.row.name).upper(), {
                        _AppKit.NSFontAttributeName:
                            _AppKit.NSFont.systemFontOfSize_weight_(11, _AppKit.NSFontWeightSemibold),
                        _AppKit.NSForegroundColorAttributeName:
                            _AppKit.NSColor.secondaryLabelColor(),
                        _AppKit.NSKernAttributeName: 0.6,
                    })
                size = text.size()
                text.drawAtPoint_(_AppKit.NSMakePoint(
                    _HEADER_INSET, (bounds.size.height - size.height) / 2))

            def _draw_device(self, bounds):
                if self.image is not None:
                    self.image.drawInRect_fromRect_operation_fraction_(
                        _AppKit.NSMakeRect(_LEFT_INSET,
                                           (bounds.size.height - _ICON_PT) / 2,
                                           _ICON_PT, _ICON_PT),
                        _AppKit.NSZeroRect,
                        _const(_AppKit, "NSCompositingOperationSourceOver", default=2), 1.0)

                name = _AppKit.NSAttributedString.alloc().initWithString_attributes_(
                    str(self.row.name), {
                        _AppKit.NSFontAttributeName: _AppKit.NSFont.menuFontOfSize_(0),
                        _AppKit.NSForegroundColorAttributeName: _AppKit.NSColor.labelColor(),
                    })
                x = _LEFT_INSET + _ICON_PT + _GAP
                size = name.size()
                y = (bounds.size.height - size.height) / 2
                name.drawAtPoint_(_AppKit.NSMakePoint(x, y))

                # The detail is a status, not part of the name: it belongs in its
                # own column against the trailing edge, just inside the dot.
                detail = str(getattr(self.row, "detail", "") or "")
                if detail:
                    aside = _AppKit.NSAttributedString.alloc().initWithString_attributes_(
                        detail, {
                            _AppKit.NSFontAttributeName: _AppKit.NSFont.menuFontOfSize_(11),
                            _AppKit.NSForegroundColorAttributeName:
                                _AppKit.NSColor.secondaryLabelColor(),
                        })
                    aside_size = aside.size()
                    right = bounds.size.width - _DOT_RIGHT_INSET - _DOT_PT - _DETAIL_GAP
                    aside.drawAtPoint_(_AppKit.NSMakePoint(
                        max(x + size.width + 8, right - aside_size.width),
                        (bounds.size.height - aside_size.height) / 2))

                # The dot, measured from the row's trailing edge so every row
                # agrees on where it goes.
                colour = _AppKit.NSColor.systemGreenColor() if self.row.online \
                    else _AppKit.NSColor.tertiaryLabelColor()
                colour.set()
                rect = _AppKit.NSMakeRect(bounds.size.width - _DOT_RIGHT_INSET - _DOT_PT,
                                          (bounds.size.height - _DOT_PT) / 2,
                                          _DOT_PT, _DOT_PT)
                _AppKit.NSBezierPath.bezierPathWithOvalInRect_(rect).fill()

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
        _RowView = None
