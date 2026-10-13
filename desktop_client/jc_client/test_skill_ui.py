"""Tests for ``ui_look`` / ``ui_do`` (skills/ui.py) on a fake accessibility tree.

No real AX calls, screen capture or cursor: the adapter, capture and input
helpers are swapped for fakes.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_skill_ui.py -q
"""
from __future__ import annotations

import pytest
from PIL import Image

from jc_client.skills import ui


def _el(role, label="", pos=(0, 0), size=(10, 10), children=(), actions=("AXPress",), **extra):
    return {"attrs": {"AXRole": role, "AXTitle": label, "AXPosition": pos, "AXSize": size, **extra},
            "children": list(children), "actions": list(actions)}


class FakeAX:
    def __init__(self, window, *, trusted=True, front=(10, "Calc"), press_ok=True, set_ok=True):
        self.win, self._trusted, self.front = window, trusted, front
        self.press_ok, self.set_ok = press_ok, set_ok
        self.pressed, self.values, self.focused = [], [], []

    def trusted(self):
        return self._trusted

    def frontmost(self):
        return self.front

    def find_app(self, name):
        return (10, "Calc") if name.lower() == "calc" else None

    def app_name(self, pid):
        return "Calc" if pid == 10 else None

    def activate(self, pid):
        pass

    def app_element(self, pid):
        return {"pid": pid}

    def window(self, app_el):
        return self.win

    def attrs(self, el, names):
        out = {n: el["attrs"].get(n) for n in names}
        if "AXChildren" in names:
            out["AXChildren"] = el["children"]
        return out

    def actions(self, el):
        return el["actions"]

    def press(self, el):
        self.pressed.append(el["attrs"]["AXTitle"])
        return self.press_ok

    def set_value(self, el, text):
        self.values.append((el["attrs"]["AXTitle"], text))
        return self.set_ok

    def focus(self, el):
        self.focused.append(el["attrs"]["AXTitle"])
        return True


def _window():
    return _el("AXWindow", "Calc", pos=(100, 50), size=(200, 100), actions=(), children=[
        _el("AXGroup", actions=(), children=[
            _el("AXButton", "7", pos=(110, 60), size=(20, 20)),
            _el("AXStaticText", "42", pos=(150, 60), size=(40, 20), actions=()),
            _el("AXTextField", "Search", pos=(110, 100), size=(80, 20), actions=()),
            _el("AXButton", "off-window", pos=(500, 500), size=(20, 20)),
            _el("AXButton", "disabled", pos=(140, 120), size=(20, 20), AXEnabled=False),
            _el("AXButton", "", pos=(280, 52), size=(12, 12), AXSubrole="AXCloseButton"),
        ]),
    ])


def _capture(frame, pid=None):
    # A Retina-like capture: 2 px per point.
    return Image.new("RGB", (int(frame[2] * 2), int(frame[3] * 2)), (40, 40, 40)), None


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    ui._looks.clear()
    monkeypatch.setattr(ui, "_ocr", lambda cg, frame: [])
    yield
    ui._looks.clear()


def test_look_lists_actionable_visible_enabled_elements_with_image_boxes():
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    assert r["ok"] and r["app"] == "Calc" and r["window"] == "Calc"
    assert [(e["i"], e["role"], e["label"]) for e in r["elements"]] == [
        (1, "AXButton", "7"), (2, "AXTextField", "Search"), (3, "AXButton", "close button")]
    # (110,60) in a window at (100,50), 2 px per point → (20,20), 20 pt → 40 px.
    assert r["elements"][0]["box"] == [20, 20, 40, 40]
    assert r["scale"] == 2.0 and r["mime"] == "image/jpeg" and r["base64"]
    assert r["look_id"] in ui._looks


def test_look_downscales_to_width():
    r = ui.read_window(ax=FakeAX(_window()), capture=_capture, width=200)
    assert r["width"] == 200 and r["scale"] == 1.0
    assert r["elements"][0]["box"] == [10, 10, 20, 20]


def test_look_caps_elements_and_sig_is_stable():
    ax = FakeAX(_window())
    a = ui.read_window(ax=ax, capture=_capture, max_elements=1)
    b = ui.read_window(ax=ax, capture=_capture, max_elements=1)
    assert len(a["elements"]) == 1 and a["sig"] == b["sig"]


def test_untrusted_process_gets_a_clear_error():
    r = ui.read_window(ax=FakeAX(_window(), trusted=False), capture=_capture)
    assert r["ok"] is False and "Accessibility" in r["error"]


def test_named_app_not_running():
    r = ui.read_window(app="Notes", ax=FakeAX(_window()), capture=_capture)
    assert r["ok"] is False and "isn't running" in r["error"]


def test_click_presses_through_accessibility(monkeypatch):
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    monkeypatch.setattr(ui, "_cursor_click", lambda *a, **k: pytest.fail("cursor must not move"))
    out = ui.do_action("click", look_id=r["look_id"], element=1, ax=ax)
    assert out == {"ok": True, "did": "click", "via": "ax"} and ax.pressed == ["7"]


def test_click_without_axpress_uses_the_cursor(monkeypatch):
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    clicks = []
    monkeypatch.setattr(ui, "_cursor_click", lambda ax_, pid, x, y, count=1: clicks.append((pid, x, y)))
    out = ui.do_action("click", look_id=r["look_id"], element=2, ax=ax)  # the text field has no AXPress
    assert out["via"] == "cursor" and clicks == [(10, 150.0, 110.0)]


def test_click_pixels_map_back_to_points(monkeypatch):
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    clicks = []
    monkeypatch.setattr(ui, "_cursor_click", lambda ax_, pid, x, y, count=1: clicks.append((x, y)))
    ui.do_action("click", look_id=r["look_id"], x=40, y=20, ax=ax)
    assert clicks == [(120.0, 60.0)]


def test_fill_sets_the_value_or_types(monkeypatch):
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    assert ui.do_action("fill", look_id=r["look_id"], element=2, text="lo-fi", ax=ax)["via"] == "ax"
    assert ax.values == [("Search", "lo-fi")]
    ax.set_ok = False
    typed, keys = [], []
    monkeypatch.setattr(ui, "_type", lambda ax_, pid, t: typed.append(t))
    monkeypatch.setattr(ui, "_keys", lambda ax_, pid, k: keys.append(k))
    out = ui.do_action("fill", look_id=r["look_id"], element=2, text="lo-fi", ax=ax)
    assert out["via"] == "keys" and keys == ["cmd+a"] and typed == ["lo-fi"] and ax.focused == ["Search"]


def test_do_unknown_look_id():
    out = ui.do_action("click", look_id="gone", element=1, ax=FakeAX(_window()))
    assert out["ok"] is False and "look again" in out["error"]


def test_do_unknown_element():
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    out = ui.do_action("click", look_id=r["look_id"], element=99, ax=ax)
    assert out["ok"] is False and "look again" in out["error"]


def test_key_and_scroll(monkeypatch):
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    keys, scrolls = [], []
    monkeypatch.setattr(ui, "_keys", lambda ax_, pid, k: keys.append((pid, k)))
    monkeypatch.setattr(ui, "_scroll", lambda ax_, pid, x, y, d: scrolls.append((x, y, d)))
    assert ui.do_action("key", look_id=r["look_id"], keys="cmd+f", ax=ax)["ok"]
    assert ui.do_action("scroll", look_id=r["look_id"], direction="down", ax=ax)["ok"]
    assert keys == [(10, "cmd+f")] and scrolls == [(200.0, 100.0, "down")]


def test_do_and_look_reads_the_same_app_again(monkeypatch):
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    monkeypatch.setattr(ui, "_ax", lambda: ax)
    calls = []

    def reader(**kw):
        calls.append(kw)
        return {"ok": True, "sig": "new"}

    out = ui.do_and_look("click", reader=reader, look_id=r["look_id"], element=1)
    assert out["ok"] and out["look"] == {"ok": True, "sig": "new"} and calls == [{"pid": 10}]


def test_keys_refused_when_the_target_app_is_not_in_front(monkeypatch):
    """He switched apps mid-task: keys/cursor must never land in the app he is using."""
    ax = FakeAX(_window(), front=(99, "Brave Browser"))
    r = ui.read_window(app="calc", ax=ax, capture=_capture)
    monkeypatch.setattr(ui, "_user_idle_s", lambda: 5.0)  # he is idle; the app just won't come forward
    sent = []
    monkeypatch.setattr("jc_client.skills.common.key_press", lambda keys: sent.append(keys))
    monkeypatch.setattr(ui.time, "sleep", lambda s: None)
    out = ui.do_action("key", look_id=r["look_id"], keys="return", ax=ax)
    assert out["ok"] is False and "in front" in out["error"] and sent == []
    clicks = []
    monkeypatch.setattr(ui, "_pointer", lambda: pytest.fail("cursor must not move"))
    out = ui.do_action("click", look_id=r["look_id"], element=2, ax=ax)  # no AXPress → would need the cursor
    assert out["ok"] is False and "in front" in out["error"]


def test_accessibility_press_still_works_in_the_background():
    ax = FakeAX(_window(), front=(99, "Brave Browser"))
    r = ui.read_window(app="calc", ax=ax, capture=_capture)
    assert ui.do_action("click", look_id=r["look_id"], element=1, ax=ax)["via"] == "ax"


def test_after_open_app_the_next_look_reads_that_app(monkeypatch):
    ax = FakeAX(_window())
    monkeypatch.setattr(ui, "_ax", lambda: ax)
    monkeypatch.setattr(ui, "_open_app", lambda name: None)
    calls = []
    out = ui.do_and_look("open_app", reader=lambda **kw: calls.append(kw) or {"ok": True, "sig": "x"}, app="Calc")
    assert out["ok"] and calls == [{"app": "Calc"}]


def test_settle_stops_as_soon_as_the_screen_changes(monkeypatch):
    sigs = iter(["same", "same", "changed", "later"])
    monkeypatch.setattr(ui, "quick_sig", lambda ax, pid: next(sigs))
    slept = []
    monkeypatch.setattr(ui.time, "sleep", slept.append)
    ui.settle(None, 10, "same")
    assert len(slept) == 3  # read twice unchanged, third read changed → stop


def test_static_text_changes_count_as_a_screen_change():
    win = _window()
    a = ui.quick_sig_of(FakeAX(win), win)
    win["children"][0]["children"][1]["attrs"]["AXValue"] = "84"
    assert ui.quick_sig_of(FakeAX(win), win) != a


def test_frontmost_and_find_app_come_from_the_live_window_list(monkeypatch):
    """NSWorkspace goes stale in the long-running client (no main run loop): a just
    launched Calculator read as "not running" and the frontmost app never changed."""
    wins = [{"kCGWindowOwnerPID": 7, "kCGWindowOwnerName": "Dock", "kCGWindowLayer": 20},
            {"kCGWindowOwnerPID": 42, "kCGWindowOwnerName": "Calculator", "kCGWindowLayer": 0},
            {"kCGWindowOwnerPID": 9, "kCGWindowOwnerName": "Brave Browser", "kCGWindowLayer": 0}]
    monkeypatch.setattr(ui, "_window_list", lambda on_screen: wins)
    ax = ui._MacAX.__new__(ui._MacAX)
    assert ax.frontmost() == (42, "Calculator")
    assert ax.find_app("calculator") == (42, "Calculator")
    assert ax.find_app("Brave Browser") == (9, "Brave Browser")
    assert ax.find_app("Notes") is None
    assert ax.app_name(9) == "Brave Browser"


def test_ui_do_without_look_id_uses_the_latest_look():
    ax = FakeAX(_window())
    ui.read_window(ax=ax, capture=_capture)
    assert ui.do_action("click", element=1, ax=ax) == {"ok": True, "did": "click", "via": "ax"}


def test_open_url_opens_the_page_in_the_app_and_waits_for_its_title(monkeypatch):
    ax = FakeAX(_window())
    opened, titles = [], iter(["Start Page", "Start Page", "Amazon.com : computer"])
    monkeypatch.setattr(ui, "_open", lambda args: opened.append(args))
    monkeypatch.setattr(ui, "_title_of", lambda ax_, app: next(titles, "Amazon.com : computer"))
    monkeypatch.setattr(ui.time, "sleep", lambda s: None)
    out = ui.do_action("open_url", url="https://www.amazon.com/s?k=computer", app="Safari", ax=ax)
    assert out == {"ok": True, "did": "open_url", "via": "app"}
    assert opened == [["-a", "Safari", "https://www.amazon.com/s?k=computer"]]
    assert ui.do_action("open_url", url="file:///etc/passwd", app="Safari", ax=ax)["ok"] is False


def test_keys_need_a_live_look():
    ui._looks.clear()
    out = ui.do_action("key", keys="return", ax=FakeAX(_window()))
    assert out["ok"] is False and "look again" in out["error"]


def test_no_typing_or_cursor_while_he_is_using_the_mac(monkeypatch):
    """Keys/clicks only when his last input is older than ours (else he is typing / in Spotlight)."""
    ax = FakeAX(_window())
    r = ui.read_window(ax=ax, capture=_capture)
    monkeypatch.setattr(ui, "_user_idle_s", lambda: 0.1)      # he touched the Mac 0.1 s ago
    monkeypatch.setattr(ui, "_last_own", [0.0])               # we haven't sent anything since
    monkeypatch.setattr(ui, "USER_WAIT_S", 0.0)
    sent = []
    monkeypatch.setattr("jc_client.skills.common.key_press", lambda keys: sent.append(keys))
    out = ui.do_action("key", look_id=r["look_id"], keys="return", ax=ax)
    assert out["ok"] is False and "using the Mac" in out["error"] and sent == []
    assert ui.do_action("click", look_id=r["look_id"], element=1, ax=ax)["via"] == "ax"  # presses still fine
    monkeypatch.setattr(ui, "_user_idle_s", lambda: 5.0)
    assert ui.do_action("key", look_id=r["look_id"], keys="return", ax=ax)["ok"] is True and sent


def test_typing_stops_if_the_app_leaves_the_front(monkeypatch):
    ax = FakeAX(_window())
    monkeypatch.setattr(ui, "_user_idle_s", lambda: 5.0)
    typed = []
    monkeypatch.setattr("jc_client.skills.common.type_text", lambda text: typed.append(text))
    fronts = iter([(10, "Calc")] * 2 + [(99, "Brave Browser")] * 10)
    ax.frontmost = lambda: next(fronts)
    with pytest.raises(ui.NotInFront):
        ui._type(ax, 10, "a long sentence to type")
    assert typed and "".join(typed) != "a long sentence to type"


def test_look_returns_the_window_text():
    r = ui.read_window(ax=FakeAX(_window()), capture=_capture)
    assert r["text"] == "42"  # the static text, even though it isn't clickable


def test_unlabelled_rows_and_icon_buttons_take_a_label_from_inside():
    """Finder's sidebar row "Downloads" has no label of its own: its text is a child."""
    win = _el("AXWindow", "Finder", pos=(0, 0), size=(300, 300), actions=(), children=[
        _el("AXRow", "", pos=(10, 10), size=(100, 20), children=[
            _el("AXCell", "", pos=(10, 10), size=(100, 20), actions=(), children=[
                _el("AXStaticText", "", pos=(12, 12), size=(60, 16), actions=(), AXValue="Downloads")])]),
        _el("AXButton", "", pos=(200, 10), size=(20, 20), AXHelp="Share"),
    ])
    r = ui.read_window(ax=FakeAX(win), capture=_capture)
    labels = {e["role"]: e["label"] for e in r["elements"]}
    assert labels["AXRow"] == "Downloads" and labels["AXButton"] == "Share"


def test_link_text_is_part_of_the_window_text():
    win = _el("AXWindow", "HN", pos=(0, 0), size=(300, 300), actions=(), children=[
        _el("AXLink", "Language Models Can Hide Things", pos=(10, 10), size=(200, 20))])
    assert "Language Models Can Hide Things" in ui.read_window(ax=FakeAX(win), capture=_capture)["text"]
