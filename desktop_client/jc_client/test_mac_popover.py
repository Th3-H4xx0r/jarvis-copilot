"""Menubar voice popover: click routing and the menu hand-off.

The AppKit views themselves need a run loop, so what is covered here is the
logic that decides things — which click does what, that pystray's menu is held
aside rather than lost, and that every failure path still leaves the user with
the separate window.
"""
from __future__ import annotations

import pytest

from jc_client import mac_popover


class _FakeButton:
    def __init__(self):
        self.target = None
        self.action = None
        self.mask = None
        self.clicks = 0

    def setTarget_(self, target):
        self.target = target

    def setAction_(self, action):
        self.action = action

    def sendActionOn_(self, mask):
        self.mask = mask

    def performClick_(self, _sender):
        self.clicks += 1

    def bounds(self):
        return (0, 0, 24, 24)


class _FakeStatusItem:
    def __init__(self, menu="the-menu"):
        self._menu = menu
        self._button = _FakeButton()
        self.menu_history = []

    def button(self):
        return self._button

    def menu(self):
        return self._menu

    def setMenu_(self, menu):
        self._menu = menu
        self.menu_history.append(menu)


class _FakeIcon:
    def __init__(self, status_item=None):
        if status_item is not None:
            self._status_item = status_item
        self.menu_updates = 0

    def _update_menu(self):
        self.menu_updates += 1


def _popover(status_item=None, on_open_window=lambda: None):
    return mac_popover.MenuBarVoicePopover(_FakeIcon(status_item), on_open_window)


def test_the_first_spelling_of_a_renamed_constant_wins():
    module = type("M", (), {"NSMinYEdge": 1})
    assert mac_popover._const(module, "NSRectEdgeMinY", "NSMinYEdge") == 1
    assert mac_popover._const(module, "NSNope", default=7) == 7


def test_install_is_a_no_op_off_macos(monkeypatch):
    monkeypatch.setattr(mac_popover.sys, "platform", "win32")
    assert mac_popover.install(_FakeIcon(_FakeStatusItem()), lambda: None) is None


@pytest.mark.skipif(mac_popover._ClickDelegate is None, reason="needs PyObjC")
def test_install_declines_when_pystray_exposes_no_status_item():
    assert _popover().install() is False


@pytest.mark.skipif(mac_popover._ClickDelegate is None, reason="needs PyObjC")
def test_installing_takes_the_menu_off_the_item_and_keeps_it():
    item = _FakeStatusItem(menu="built-menu")
    panel = _popover(item)
    assert panel.install() is True
    # AppKit opens an attached menu on ANY mouse-down and never calls the
    # button's action, so the item must be left without one.
    assert item.menu() is None
    assert panel._menu == "built-menu"
    assert item.button().action == b"statusClick:"


@pytest.mark.skipif(mac_popover._ClickDelegate is None, reason="needs PyObjC")
def test_a_menu_rebuild_is_detached_again():
    item = _FakeStatusItem()
    icon = _FakeIcon(item)
    panel = mac_popover.MenuBarVoicePopover(icon, lambda: None)
    assert panel.install() is True

    item.setMenu_("rebuilt")       # what pystray does on every refresh
    icon._update_menu()            # …through our wrapper
    assert item.menu() is None
    assert panel._menu == "rebuilt"
    assert icon.menu_updates == 1


@pytest.mark.skipif(mac_popover._ClickDelegate is None, reason="needs PyObjC")
def test_a_right_click_shows_the_menu_and_a_left_click_the_orb(monkeypatch):
    item = _FakeStatusItem()
    panel = _popover(item)
    assert panel.install() is True
    opened = []
    monkeypatch.setattr(panel, "toggle", lambda: opened.append("orb"))

    monkeypatch.setattr(panel, "_is_secondary_click", lambda: True)
    panel.handle_click()
    assert item.button().clicks == 1, "the menu is shown by clicking the button again"
    assert item.menu() is None, "and taken straight back off"
    assert opened == []

    monkeypatch.setattr(panel, "_is_secondary_click", lambda: False)
    panel.handle_click()
    assert opened == ["orb"]


@pytest.mark.skipif(mac_popover._ClickDelegate is None, reason="needs PyObjC")
def test_the_orb_falls_back_to_the_window_when_the_panel_cannot_be_built(monkeypatch):
    windows = []
    panel = _popover(_FakeStatusItem(), on_open_window=lambda: windows.append(1))
    monkeypatch.setattr(panel, "_ensure_popover", lambda: None)
    panel.toggle()
    assert windows == [1], "an unpaired or broken panel still gets you the orb"


def test_open_in_window_hands_off():
    windows = []
    panel = _popover(on_open_window=lambda: windows.append(1))
    panel.open_in_window()
    assert windows == [1]


def test_a_failing_hand_off_does_not_escape():
    def boom():
        raise RuntimeError("no window today")

    _popover(on_open_window=boom).open_in_window()  # must not raise


def test_shutdown_stops_the_loopback_proxy():
    class _Proxy:
        def __init__(self):
            self.stopped = False

        def shutdown(self):
            self.stopped = True

    panel = _popover()
    proxy = _Proxy()
    panel._proxy = proxy
    panel.shutdown()
    assert proxy.stopped is True
    assert panel._proxy is None


def test_a_missing_dylib_leaves_the_web_panel_in_place(monkeypatch, tmp_path):
    """No dylib is a fallback, not a failure — `build.sh` may never have run."""
    monkeypatch.setattr(mac_popover, "_panel_class", mac_popover._UNSET)
    monkeypatch.setattr(mac_popover, "__file__", str(tmp_path / "mac_popover.py"))
    assert mac_popover._voice_panel_class() is None


def test_the_dylib_is_only_looked_for_once(monkeypatch, tmp_path):
    monkeypatch.setattr(mac_popover, "_panel_class", mac_popover._UNSET)
    monkeypatch.setattr(mac_popover, "__file__", str(tmp_path / "mac_popover.py"))
    assert mac_popover._voice_panel_class() is None
    # A second call must not re-open the dylib; the cached answer stands even if
    # the file appears afterwards.
    (tmp_path / "assets").mkdir()
    (tmp_path / "assets" / "libJarvisVoiceUI.dylib").write_bytes(b"not a dylib")
    assert mac_popover._voice_panel_class() is None


def test_quitting_stops_a_running_conversation(monkeypatch):
    """Closing the popover only hides it; the mic and socket outlive it."""
    stopped = []

    class _PanelClass:
        @staticmethod
        def stopEverything():
            stopped.append(True)

    monkeypatch.setattr(mac_popover, "_panel_class", _PanelClass)
    popover = _popover()
    popover._panel = object()          # a controller is installed
    popover.shutdown()
    assert stopped == [True]


def test_a_panel_that_will_not_stop_does_not_block_the_quit():
    class _PanelClass:
        @staticmethod
        def stopEverything():
            raise RuntimeError("already gone")

    class _Proxy:
        def __init__(self):
            self.stopped = False

        def shutdown(self):
            self.stopped = True

    popover = _popover()
    popover._panel = object()
    popover._proxy = proxy = _Proxy()
    mac_popover._panel_class = _PanelClass
    try:
        popover.shutdown()
    finally:
        mac_popover._panel_class = mac_popover._UNSET
    # The proxy still came down, which is the part that holds a port.
    assert proxy.stopped is True


def _health(monkeypatch, *, darwin=True, cls=None, error=None, dylib=True, tmp_path=None):
    monkeypatch.setattr(mac_popover.sys, "platform", "darwin" if darwin else "linux")
    monkeypatch.setattr(mac_popover, "_panel_class", cls)
    monkeypatch.setattr(mac_popover, "_panel_error", error)
    path = (tmp_path / "libJarvisVoiceUI.dylib") if tmp_path else None
    if path is not None and dylib:
        path.write_bytes(b"")
    monkeypatch.setattr(mac_popover, "_dylib_path",
                        lambda: path if path is not None else __import__("pathlib").Path("/nope"))
    return mac_popover.voice_panel_health()


def test_health_is_not_a_question_off_macos(monkeypatch):
    ok, detail = _health(monkeypatch, darwin=False)
    assert ok is False and "macOS only" in detail


def test_health_names_the_build_step_when_the_dylib_was_never_built(monkeypatch, tmp_path):
    ok, detail = _health(monkeypatch, dylib=False, tmp_path=tmp_path)
    assert ok is False
    assert "build.sh" in detail


def test_health_repeats_why_the_dylib_would_not_load(monkeypatch, tmp_path):
    """The ctypes message names the cause — a wrong architecture, say."""
    ok, detail = _health(monkeypatch, cls=None,
                         error="incompatible architecture (have 'arm64', need 'x86_64')",
                         tmp_path=tmp_path)
    assert ok is False
    assert "incompatible architecture" in detail


def test_health_is_good_when_the_panel_and_its_shader_are_there(monkeypatch, tmp_path):
    class _Cls:
        @staticmethod
        def orbShaderAvailable():
            return True

    ok, detail = _health(monkeypatch, cls=_Cls, tmp_path=tmp_path)
    assert ok is True and detail == "native panel"


def test_a_loaded_panel_with_no_shader_is_still_a_working_panel(monkeypatch, tmp_path):
    """The orb goes missing; the conversation does not. Say so without crying wolf."""
    class _Cls:
        @staticmethod
        def orbShaderAvailable():
            return False

    ok, detail = _health(monkeypatch, cls=_Cls, tmp_path=tmp_path)
    assert ok is True
    assert "shader" in detail and "build.sh" in detail
