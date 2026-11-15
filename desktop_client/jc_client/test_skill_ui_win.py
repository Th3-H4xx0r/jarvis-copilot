"""Computer control on the PC (ui_look / ui_do over UI Automation), with the Mac's contract:
numbered boxes on a window screenshot, the same result keys, presses before the cursor, and
keys that never land in an app he's using. Driven through a fake backend (runs anywhere)."""
import pytest
from PIL import Image

from jc_client.skills import ui_win


class FakeBackend:
    def __init__(self):
        self.calls = []
        self.front = (100, "notepad")
        self.idle = 5.0
        self.elements = [
            {"role": "AXTextArea", "label": "Text editor", "pt": (110, 160, 400, 300), "ref": "edit"},
            {"role": "AXButton", "label": "Close", "pt": (480, 110, 30, 20), "ref": "close"},
        ]
        self.invokable = {"close"}
        self.settable = {"edit"}

    def frontmost(self): return self.front
    def find_window(self, app): return (100, "notepad") if app.lower() in ("notepad", "notepad.exe") else None
    def window_rect(self, hwnd): return (100, 100, 800, 600)
    def title(self, hwnd): return "Untitled - Notepad"
    def walk(self, hwnd, frame, max_elements, texts): return [dict(e) for e in self.elements][:max_elements]
    def capture(self, hwnd, frame): return Image.new("RGB", (frame[2], frame[3]), (30, 30, 30))
    def invoke(self, ref): self.calls.append(("invoke", ref)); return ref in self.invokable
    def set_value(self, ref, text): self.calls.append(("set_value", ref, text)); return ref in self.settable
    def focus(self, ref): self.calls.append(("focus", ref)); return True
    def activate(self, hwnd): self.calls.append(("activate", hwnd)); self.front = (hwnd, "notepad")
    def idle_seconds(self): return self.idle
    def click(self, x, y, count=1): self.calls.append(("click", round(x), round(y)))
    def keys(self, combo): self.calls.append(("keys", combo))
    def type_text(self, text): self.calls.append(("type", text))
    def scroll_at(self, x, y, direction): self.calls.append(("scroll", direction))
    def open_app(self, name): self.calls.append(("open_app", name))
    def open_url(self, url): self.calls.append(("open_url", url))


@pytest.fixture
def be(monkeypatch):
    b = FakeBackend()
    monkeypatch.setattr(ui_win, "_backend", lambda: b)
    ui_win._looks.clear()
    ui_win._last_own[0] = 0.0   # no move of ours just happened
    return b


def test_look_numbers_elements_and_matches_the_macs_keys(be):
    out = ui_win.read_window()
    assert out["ok"] is True and out["app"] == "notepad" and out["window"] == "Untitled - Notepad"
    for key in ("look_id", "width", "height", "origin", "scale", "base64", "mime", "elements", "source", "sig", "ms", "text"):
        assert key in out, key
    assert out["source"] == "uia" and out["mime"] == "image/jpeg"
    assert [e["i"] for e in out["elements"]] == [1, 2]
    assert out["elements"][0]["box"] == [10, 60, 400, 300]     # window-relative, scale 1 (800 ≤ 1024)
    assert out["elements"][1]["role"] == "AXButton"


def test_look_scales_wide_windows_down(be, monkeypatch):
    monkeypatch.setattr(be, "window_rect", lambda hwnd: (0, 0, 2048, 1000))
    out = ui_win.read_window()
    assert out["width"] == 1024 and out["scale"] == 0.5


def test_look_named_app_not_running(be):
    out = ui_win.read_window(app="spotify")
    assert out == {"ok": False, "error": "spotify isn't running. Open it first (open_app)."}


def test_click_prefers_invoke_pattern(be):
    look = ui_win.read_window()
    out = ui_win.do_action("click", look_id=look["look_id"], element=2)
    assert out == {"ok": True, "did": "click", "via": "uia"}
    assert ("invoke", "close") in be.calls and not any(c[0] == "click" for c in be.calls)


def test_click_falls_back_to_the_cursor_at_the_centre(be):
    be.invokable = set()
    look = ui_win.read_window()
    out = ui_win.do_action("click", look_id=look["look_id"], element=2)
    assert out["via"] == "cursor" and ("click", 495, 120) in be.calls


def test_fill_uses_value_pattern(be):
    look = ui_win.read_window()
    out = ui_win.do_action("fill", look_id=look["look_id"], element=1, text="hello")
    assert out == {"ok": True, "did": "fill", "via": "uia"}
    assert ("set_value", "edit", "hello") in be.calls


def test_keys_map_mac_names_to_windows(be):
    look = ui_win.read_window()
    ui_win.do_action("key", look_id=look["look_id"], keys="cmd+f")
    assert ("keys", ["ctrl", "f"]) in be.calls


def test_keys_refused_while_he_types(be, monkeypatch):
    look = ui_win.read_window()
    be.idle = 0.0
    monkeypatch.setattr(ui_win, "USER_WAIT_S", 0.05)
    out = ui_win.do_action("key", look_id=look["look_id"], keys="return")
    assert out["ok"] is False and "using the PC" in out["error"]
    assert not any(c[0] == "keys" for c in be.calls)


def test_unknown_element_and_stale_screen(be):
    look = ui_win.read_window()
    assert ui_win.do_action("click", look_id=look["look_id"], element=9)["error"].startswith("There is no element 9")
    ui_win._looks.clear()
    assert ui_win.do_action("fill", look_id="gone", element=1, text="x") == {"ok": False, "error": "That screen is gone; look again."}


def test_open_url_needs_http(be):
    assert ui_win.do_action("open_url", url="file:///etc")["ok"] is False
    assert ui_win.do_action("open_url", url="https://example.com")["ok"] is True


def test_map_combo():
    assert ui_win.map_keys("cmd+shift+t") == ["ctrl", "shift", "t"]
    assert ui_win.map_keys("option+tab") == ["alt", "tab"]
    assert ui_win.map_keys("return") == ["enter"]


def test_role_mapping():
    assert ui_win.ax_role("ButtonControl") == "AXButton"
    assert ui_win.ax_role("EditControl") == "AXTextField"
    assert ui_win.ax_role("PaneControl") is None
