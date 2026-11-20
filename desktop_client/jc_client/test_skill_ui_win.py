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
    def open_url(self, url, app=None): self.calls.append(("open_url", url, app))


@pytest.fixture
def be(monkeypatch):
    b = FakeBackend()
    monkeypatch.setattr(ui_win, "_backend", lambda: b)
    monkeypatch.setattr(ui_win, "_ad_client", lambda: None)  # agent-desktop absent unless a test says so
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


# ── agent-desktop first on the PC, proved moves, batched clicks ───────────────

def _bx(x, y, w=40, h=20):
    return {"x": x, "y": y, "width": w, "height": h}


PC_SNAPSHOT = {"ok": True, "data": {
    "app": "Notepad", "complete": True, "ref_count": 2, "snapshot_id": "p1",
    "window": {"id": "w-7", "title": "Untitled - Notepad", "bounds": _bx(100, 100, 800, 600)},
    "tree": {"role": "window", "children": [
        {"role": "textfield", "name": "Text editor", "ref_id": "@p1:e1", "bounds": _bx(110, 160, 400, 300)},
        {"role": "button", "name": "Close", "ref_id": "@p1:e2", "bounds": _bx(480, 110, 30, 20)},
        {"role": "statictext", "name": "Ln 1, Col 1"},
    ]}}}
VERIFIED = {"ok": True, "data": {"disposition": {"delivery": "delivered_verified"}}}


class FakeAD:
    def __init__(self, *replies):
        self.replies, self.calls = list(replies), []

    def call(self, tool, args, timeout=8.0):
        self.calls.append((tool, args))
        return self.replies.pop(0) if self.replies else VERIFIED


def test_pc_look_uses_agent_desktop_first(be, monkeypatch):
    ad = FakeAD(PC_SNAPSHOT)
    monkeypatch.setattr(ui_win, "_ad_client", lambda: ad)
    out = ui_win.read_window(app="notepad")
    assert out["ok"] and out["engine"] == "agent-desktop" and out["source"] == "agent-desktop"
    assert [(e["i"], e["role"], e["label"]) for e in out["elements"]] == [(1, "AXTextField", "Text editor"),
                                                                       (2, "AXButton", "Close")]
    assert out["elements"][0]["box"] == [10, 60, 400, 300] and "Ln 1, Col 1" in out["text"]
    assert ad.calls[0][1]["app"] == "notepad"


def test_pc_look_falls_back_to_uia_with_note(be, monkeypatch):
    ad = FakeAD({"ok": False, "error": {"code": "WINDOW_NOT_FOUND", "message": "no window"}})
    monkeypatch.setattr(ui_win, "_ad_client", lambda: ad)
    out = ui_win.read_window(app="notepad")
    assert out["ok"] and out["engine"] == "uia" and out["engine_note"] == "agent-desktop: no window"


def test_pc_ad_click_and_landed(be, monkeypatch):
    ad = FakeAD(PC_SNAPSHOT, VERIFIED)
    monkeypatch.setattr(ui_win, "_ad_client", lambda: ad)
    look = ui_win.read_window(app="notepad")
    out = ui_win.do_action("click", look_id=look["look_id"], element=2)
    assert out == {"ok": True, "did": "click", "via": "agent-desktop", "landed": "yes"}
    assert ad.calls[-1] == ("desktop_click", {"ref_id": "@p1:e2"}) and not be.calls


def test_pc_clicks_batch(be, monkeypatch):
    monkeypatch.setattr(ui_win.time, "sleep", lambda s: None)
    look = ui_win.read_window()
    be.invokable = {"edit", "close"}
    out = ui_win.do_and_look("clicks", look_id=look["look_id"], elements=[2, 1])
    assert [c for c in be.calls if c[0] == "invoke"] == [("invoke", "close"), ("invoke", "edit")]
    assert out["ok"] and out["did"] == "clicks" and out["done"] == 2 and "look" in out


def test_pc_landed_unknown_without_change(be, monkeypatch):
    monkeypatch.setattr(ui_win.time, "sleep", lambda s: None)
    look = ui_win.read_window()
    out = ui_win.do_and_look("click", look_id=look["look_id"], element=2)
    assert out["ok"] and out["landed"] == "unknown"   # the same screen came back


def test_pc_skill_schemas_advertise_the_new_moves(monkeypatch):
    registered = {}
    monkeypatch.setattr("jc_client.skills.skill",
                        lambda name, desc, schema=None, **kw: (lambda fn: registered.setdefault(name, schema) and fn))
    ui_win._register()
    assert "taskbar" in registered["ui_look"]["properties"]["surface"]["enum"]
    assert "clicks" in registered["ui_do"]["properties"]["action"]["enum"]


# ── review fixes ──────────────────────────────────────────────────────────────

def test_pc_stale_ad_fill_never_types(be, monkeypatch):
    stale = {"ok": False, "error": {"code": "STALE_REF", "message": "gone", "disposition": {"delivery": "not_delivered"}}}
    ad = FakeAD(PC_SNAPSHOT, stale)
    monkeypatch.setattr(ui_win, "_ad_client", lambda: ad)
    look = ui_win.read_window(app="notepad")
    out = ui_win.do_action("fill", look_id=look["look_id"], element=1, text="secret")
    assert out["ok"] is False and not any(c[0] in ("type", "keys", "click") for c in be.calls)


def test_pc_look_without_a_window_refuses_keys(be, monkeypatch):
    shot = dict(PC_SNAPSHOT, data=dict(PC_SNAPSHOT["data"], app="explorer"))
    monkeypatch.setattr(ui_win, "_ad_client", lambda: FakeAD(shot))
    monkeypatch.setattr(be, "find_window", lambda app: None)   # File Explorer: titles are folder names
    look = ui_win.read_window(app="explorer")
    out = ui_win.do_action("key", look_id=look["look_id"], keys="ctrl+a")
    assert out["ok"] is False and not any(c[0] == "keys" for c in be.calls)


def test_pc_shell_surface_look_has_no_app_window(be, monkeypatch):
    taskbar = {"ok": True, "data": {"snapshot_id": "t1", "tree": {
        "role": "toolbar", "bounds": _bx(0, 1040, 1920, 40), "children": [
            {"role": "button", "name": "Start", "ref_id": "@t1:e1", "bounds": _bx(0, 1040, 40, 40)}]}}}
    monkeypatch.setattr(ui_win, "_ad_client", lambda: FakeAD(taskbar))
    look = ui_win.read_window(surface="taskbar")
    seen = ui_win._looks[look["look_id"]]
    assert seen["hwnd"] is None and seen["app"] is None and seen["surface"] == "taskbar"
    assert ui_win.do_action("key", look_id=look["look_id"], keys="return")["ok"] is False


def test_pc_ad_read_exception_falls_back(be, monkeypatch):
    monkeypatch.setattr(ui_win, "_ad_client", lambda: FakeAD())

    def boom(*a, **k):
        raise RuntimeError("bad tree")

    monkeypatch.setattr(ui_win.ui_ad, "read", boom)
    out = ui_win.read_window(app="notepad")
    assert out["ok"] and out["engine"] == "uia" and "bad tree" in out["engine_note"]


def test_ad_client_failure_is_logged_once(monkeypatch, caplog):
    import logging
    import jc_client.agent_desktop_client as adc_mod
    monkeypatch.setattr(ui_win, "_ad_client", ui_win._ad_client_real)
    monkeypatch.setattr(ui_win, "_ad_warned", [False])

    def boom():
        raise OSError("no access to the state dir")

    monkeypatch.setattr(adc_mod, "get", boom)
    with caplog.at_level(logging.WARNING, logger="jc_client.skills.ui_win"):
        assert ui_win._ad_client() is None
        assert ui_win._ad_client() is None
    hits = [r for r in caplog.records if "agent-desktop" in r.getMessage()]
    assert len(hits) == 1 and "no access to the state dir" in hits[0].getMessage()


def test_missing_agent_desktop_says_where_it_looked(be, monkeypatch, tmp_path):
    monkeypatch.setattr(ui_win, "_ad_expected_path", lambda: str(tmp_path / "agent-desktop.exe"))
    out = ui_win.read_window(surface="taskbar")
    assert out["ok"] is False and str(tmp_path / "agent-desktop.exe") in out["error"]



# ── live 2026-11-18: every PC cursor click crashed; open_url ignored the browser he named ──

def test_backend_click_and_scroll_use_the_mouse_controller(monkeypatch):
    import sys
    import types

    class Mouse:
        def __init__(self):
            self.position, self.clicks, self.scrolls = (5, 5), [], []

        def click(self, button, count): self.clicks.append((button, count, self.position))
        def scroll(self, dx, dy): self.scrolls.append((dy, self.position))

    fake = types.ModuleType("pynput.mouse")
    fake.Button = types.SimpleNamespace(left="L")
    monkeypatch.setitem(sys.modules, "pynput", types.ModuleType("pynput"))
    monkeypatch.setitem(sys.modules, "pynput.mouse", fake)
    m = Mouse()
    monkeypatch.setattr("jc_client.skills.common._mouse", lambda: (fake.Button, m))   # (Button, controller)
    be_ = ui_win._WinBackend.__new__(ui_win._WinBackend)
    be_.click(100, 200)
    be_.scroll_at(100, 200, "down")
    assert m.clicks == [("L", 1, (100, 200))] and m.scrolls and m.position == (5, 5)


def test_pc_open_url_uses_the_named_browser(be):
    out = ui_win.do_action("open_url", url="https://www.google.com/search?q=pcs", app="Google Chrome")
    assert out["ok"] and ("open_url", "https://www.google.com/search?q=pcs", "Google Chrome") in be.calls


def test_open_app_reports_what_it_really_launched(monkeypatch):
    # Live 2026-11-20: "Warzone" launched "Call of Duty"; the loop needs that name to find its window.
    from jc_client.skills import ui_win
    be = FakeBackend()
    be.open_app = lambda name: {"ok": True, "name": name, "launched": "Call of Duty"}
    be.find_window = lambda app: None
    monkeypatch.setattr(ui_win, "_backend", lambda: be)
    monkeypatch.setattr(ui_win.time, "sleep", lambda s: None)
    out = ui_win._do(be, "open_app", None, None, None, None, None, None, None, "Warzone", None)
    assert out["ok"] is True and out.get("launched") == "Call of Duty"



def test_a_window_windows_wont_bring_forward_is_forced(monkeypatch):
    # Live 2026-11-20: Battle.net never came to the front, so every click was refused ("isn't in front").
    from jc_client.skills import ui_win
    be = FakeBackend()
    state = {"front": 1, "tries": []}
    be.frontmost = lambda: (state["front"], "x")
    be.idle_seconds = lambda: 999.0

    def activate(hwnd, force=False):
        state["tries"].append(force)
        if force:
            state["front"] = hwnd
    be.activate = activate
    monkeypatch.setattr(ui_win.time, "sleep", lambda s: None)
    ui_win._front(be, 42)
    assert state["front"] == 42 and state["tries"][-1] is True
