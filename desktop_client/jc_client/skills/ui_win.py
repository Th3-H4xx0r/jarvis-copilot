"""Fast computer control on the PC (Windows): ``ui_look`` / ``ui_do`` with the Mac's contract
(skills/ui.py, read by the server's agent/computer loop) — one window as a screenshot with
numbered boxes plus the same numbered elements, read from UI Automation; a move presses
through UIA first (Invoke / Value patterns: the cursor never moves) and uses the real cursor
or keys only when that can't work, never while he is typing, and returns the next look.

Everything Windows-specific sits behind a backend (``_WinBackend``) so the rules here are
tested anywhere. Skills register only on win32. No OCR fallback yet (``source`` is "uia").
"""
from __future__ import annotations

import base64
import hashlib
import io
import logging
import sys
import threading
import time
import uuid
from collections import OrderedDict
from typing import Optional

from jc_client.skills import ui_ad

log = logging.getLogger("jc_client.skills.ui_win")

MAX_NODES = 4000
MAX_DEPTH = 30
WALK_BUDGET_S = 0.45
TEXT_CAP = 6000
_KEEP_LOOKS = 4
USER_WAIT_S = 1.5

# UI Automation control types → the Mac's AX role names (the server's prompts speak AX).
UIA_ROLE = {"ButtonControl": "AXButton", "CheckBoxControl": "AXCheckBox", "RadioButtonControl": "AXRadioButton",
            "ComboBoxControl": "AXComboBox", "EditControl": "AXTextField", "DocumentControl": "AXTextArea",
            "HyperlinkControl": "AXLink", "ListItemControl": "AXCell", "MenuItemControl": "AXMenuItem",
            "TabItemControl": "AXTab", "SliderControl": "AXSlider", "SplitButtonControl": "AXMenuButton",
            "TreeItemControl": "AXRow", "DataItemControl": "AXCell"}

_KEY_NAMES = {"cmd": "ctrl", "command": "ctrl", "option": "alt", "opt": "alt", "return": "enter",
              "control": "ctrl", "escape": "esc", "delete": "backspace"}

_looks: "OrderedDict[str, dict]" = OrderedDict()
_looks_lock = threading.Lock()
_act_lock = threading.Lock()


def ax_role(control_type: str) -> Optional[str]:
    return UIA_ROLE.get(control_type)


def map_keys(keys: str) -> list:
    """"cmd+shift+t" → ["ctrl", "shift", "t"]: a Mac-style combo as the PC's keys."""
    return [_KEY_NAMES.get(k.strip().lower(), k.strip().lower()) for k in str(keys or "").split("+") if k.strip()]


def _center(pt) -> tuple:
    x, y, w, h = pt
    return x + w / 2.0, y + h / 2.0


def _sig(title: str, elements: list, texts: list) -> str:
    raw = title + "|" + "|".join(f"{e['role']}:{e['label']}" for e in elements) + "|" + "|".join(texts[:50])
    return hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()[:12]


def _draw(img, elements) -> None:
    from PIL import ImageDraw, ImageFont
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=13)
    except TypeError:
        font = ImageFont.load_default()
    for e in elements:
        x, y, w, h = e["box"]
        d.rectangle([x, y, x + w, y + h], outline=(255, 0, 170), width=2)
        tag = str(e["i"])
        d.rectangle([x, y, x + 8 * len(tag) + 6, y + 16], fill=(255, 0, 170))
        d.text((x + 3, y + 1), tag, fill=(255, 255, 255), font=font)


# ── looking ──────────────────────────────────────────────────────────────────

# agent-desktop is the PC's main engine (UI Automation done properly: ref identity, waits, delivery
# evidence); this module's own UIA walk is the fallback for any look it can't take.
SURFACES = ["taskbar", "system-tray", "start-menu", "action-center", "menu", "sheet"]
# agent-desktop has no UIA way to do it: the guarded cursor/keys path may (not after STALE_REF etc.).
_NO_SEMANTIC_PATH = frozenset({"POLICY_DENIED", "ACTION_NOT_SUPPORTED", "ACTION_FAILED"})


_ad_warned = [False]


def _ad_client():
    try:
        from jc_client import agent_desktop_client
        return agent_desktop_client.get()
    except Exception as exc:
        if not _ad_warned[0]:  # once: every look would otherwise repeat it
            _ad_warned[0] = True
            log.warning("agent-desktop unavailable: %s", exc, exc_info=True)
        return None


_ad_client_real = _ad_client


def _ad_expected_path() -> str:
    try:
        import os
        from jc_client.agent_desktop_install import PINNED_VERSION
        from jc_client.logger import state_dir
        return os.path.join(str(state_dir()), "bin", f"agent-desktop-{PINNED_VERSION}", "agent-desktop.exe")
    except Exception as exc:  # noqa: BLE001
        return f"(unknown: {exc})"


def read_window(app: Optional[str] = None, max_elements: int = 250, width: int = 1024,
                surface: Optional[str] = None) -> dict:
    be = _backend()
    started = time.monotonic()
    max_elements = max(1, min(int(max_elements or 250), 400))
    note = None
    ad = _ad_client()
    if ad is not None:
        try:
            got = _read_ad(be, ad, app, surface, max_elements, width, started)
        except Exception as exc:  # a bad tree or capture: our UIA walk takes the look
            log.debug("agent-desktop look failed", exc_info=True)
            got = {"ok": False, "error": f"agent-desktop: {exc}"[:200]}
        if got.get("ok"):
            return got
        note = got.get("error") or "agent-desktop failed"
        if surface:  # the taskbar, the tray…: nothing of ours reads those
            return {"ok": False, "error": note}
    elif surface:
        return {"ok": False, "error": f"That needs agent-desktop (not found at {_ad_expected_path()}; "
                                      "run `jc-client install-agent-desktop`)."}
    if app:
        found = be.find_window(app)
        if not found:
            return {"ok": False, "error": f"{app} isn't running. Open it first (open_app)."}
        hwnd, name = found
    else:
        hwnd, name = be.frontmost()
        if not hwnd:
            return {"ok": False, "error": "No window is open on the PC."}
    frame = tuple(be.window_rect(hwnd))
    if not frame or frame[2] <= 0 or frame[3] <= 0:
        return {"ok": False, "error": f"Could not read {name}'s window."}
    texts: list = []
    elements = be.walk(hwnd, frame, max_elements, texts)
    title = str(be.title(hwnd) or "")
    img = be.capture(hwnd, frame)
    out = _finish(img, frame, elements, texts, title, name, hwnd, width, started,
                  {"source": "uia", "engine": "uia"})
    if note:
        out["engine_note"] = note
    return out


def _read_ad(be, ad, app, surface, max_elements, width, started) -> dict:
    """One look through agent-desktop, in the same shape; ``{"ok": False, "error"}`` to fall back."""
    got = ui_ad.read(ad, app=app, surface=surface, max_elements=400 if surface else max_elements)
    if not got.get("ok"):
        return got
    frame = got["frame"]
    if not frame or frame[2] <= 0 or frame[3] <= 0:
        return {"ok": False, "error": "agent-desktop: nothing to show"}
    # A shell surface (taskbar, Start…) belongs to no app window; an app agent-desktop found but our
    # window search didn't (File Explorer) has no window either — keys are refused on such looks.
    found = None if surface else (be.find_window(app) if app else be.frontmost())
    hwnd, name = found if found and found[0] else (None, None if surface else (got.get("app") or app))
    img = be.capture(hwnd, frame)
    return _finish(img, frame, got["elements"], got["texts"], str(got.get("title") or ""), name, hwnd, width,
                   started, {"source": "agent-desktop", "engine": "agent-desktop",
                             **({"surface": surface} if surface else {})})


def _finish(img, frame, elements, texts, title, name, hwnd, width, started, extra: dict) -> dict:
    """Scale, number and draw the elements, cache the look, and build the reply."""
    sig = _sig(title, elements, texts)
    scale = img.width / frame[2] if frame[2] else 1.0
    if width and img.width > width:
        r = width / img.width
        img = img.resize((width, max(1, int(img.height * r))))
        scale *= r
    for i, e in enumerate(elements, 1):
        x, y, w, h = e["pt"]
        e["i"] = i
        e["box"] = [int((x - frame[0]) * scale), int((y - frame[1]) * scale), int(w * scale), int(h * scale)]
    _draw(img, elements)
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=70)
    look_id = uuid.uuid4().hex[:10]
    with _looks_lock:
        _looks[look_id] = {"hwnd": hwnd, "app": name, "frame": frame, "scale": scale, "elements": elements,
                           "sig": sig, "engine": extra.get("engine", "uia"), "surface": extra.get("surface")}
        while len(_looks) > _KEEP_LOOKS:
            _looks.popitem(last=False)
    return {"ok": True, "look_id": look_id, "app": name, "window": title[:120], "width": img.width,
            "height": img.height, "origin": list(frame[:2]), "scale": round(scale, 4),
            "base64": base64.b64encode(buf.getvalue()).decode("ascii"), "mime": "image/jpeg",
            "elements": [{"i": e["i"], "role": e["role"], "label": e["label"], "box": e["box"],
                          **({"kind": e["kind"]} if e.get("kind") else {})} for e in elements],
            "sig": sig, "ms": int((time.monotonic() - started) * 1000), **extra,
            "text": "\n".join(t for t in texts if t.strip())[:TEXT_CAP]}


# ── acting ───────────────────────────────────────────────────────────────────

class _UserBusy(Exception):
    pass


class _NotInFront(Exception):
    pass


_last_own = [0.0]


def _wait_for_user(be) -> None:
    """Real keys/clicks only when his last input is older than ours."""
    deadline = time.monotonic() + USER_WAIT_S
    while True:
        idle = be.idle_seconds()
        if idle >= 0.8 or idle >= (time.monotonic() - _last_own[0]) - 0.05:
            return
        if time.monotonic() >= deadline:
            raise _UserBusy()
        time.sleep(0.05)


def _front(be, hwnd) -> None:
    _wait_for_user(be)
    if not hwnd or be.frontmost()[0] == hwnd:
        return
    be.activate(hwnd)
    deadline = time.monotonic() + 0.5
    while be.frontmost()[0] != hwnd:
        if time.monotonic() >= deadline:
            raise _NotInFront()
        time.sleep(0.03)


def do_action(action: str, look_id: Optional[str] = None, element: Optional[int] = None, text: Optional[str] = None,
              keys: Optional[str] = None, direction: Optional[str] = None, x: Optional[float] = None,
              y: Optional[float] = None, app: Optional[str] = None, url: Optional[str] = None) -> dict:
    be = _backend()
    try:
        return _do(be, action, look_id, element, text, keys, direction, x, y, app, url)
    except _UserBusy:
        return {"ok": False, "error": "You're using the PC right now, so I won't type or move the cursor; "
                                      "only buttons can be pressed in the background."}
    except _NotInFront:
        return {"ok": False, "error": "That app isn't in front (another app is in use), so I won't type or move "
                                      "the cursor; only its buttons can be pressed in the background."}


def _do(be, action, look_id, element, text, keys, direction, x, y, app, url) -> dict:
    with _looks_lock:
        seen = _looks.get(look_id) if look_id else (next(reversed(_looks.values())) if _looks else None)
    if seen is None and (action in ("fill", "key", "scroll")
                         or (action == "click" and (element is not None or x is not None))):
        return {"ok": False, "error": "That screen is gone; look again."}
    if seen is not None and seen.get("hwnd") is None and action in ("fill", "key"):
        return {"ok": False, "error": "Nothing is open on that screen to type into; open an app first."}
    hwnd = seen["hwnd"] if seen else be.frontmost()[0]
    el = None
    if element is not None and seen is not None:
        el = next((e for e in seen["elements"] if e["i"] == int(element)), None)
        if el is None:
            return {"ok": False, "error": f"There is no element {element} on that screen; look again."}

    def cursor_click(px, py):
        _front(be, hwnd)
        be.click(px, py)
        _last_own[0] = time.monotonic()

    if seen is not None and seen.get("engine") == "agent-desktop" and el is not None \
            and action in ("click", "fill", "scroll"):
        ad = _ad_client()
        if ad is None:
            return {"ok": False, "error": "That screen is gone; look again."}
        if action == "fill" and not text:
            return {"ok": False, "error": "fill needs an element and text"}
        res = ui_ad.act(ad, el["adref"], action, text=text, direction=direction, role=el["role"])
        if res.get("ok") or res.get("code") not in _NO_SEMANTIC_PATH or not hwnd or not any(el["pt"][2:]):
            return res  # never after STALE_REF / AMBIGUOUS_TARGET: the screen changed under it
        if action == "click":
            cursor_click(*_center(el["pt"]))
            return {"ok": True, "did": "click", "via": "cursor", "landed": "unknown"}
        if action == "scroll":
            _front(be, hwnd)
            be.scroll_at(*_center(el["pt"]), direction)
            _last_own[0] = time.monotonic()
            return {"ok": True, "did": "scroll", "via": "cursor", "landed": "unknown"}
        # It couldn't set the value: type it through the guarded path (window in front, he isn't typing).
        cursor_click(*_center(el["pt"]))
        _front(be, hwnd)
        be.keys(["ctrl", "a"])
        be.type_text(text)
        _last_own[0] = time.monotonic()
        return {"ok": True, "did": "fill", "via": "keys", "landed": "unknown"}

    if action == "click":
        if el is not None:
            if el.get("ref") is not None and be.invoke(el["ref"]):
                return {"ok": True, "did": "click", "via": "uia"}
            cursor_click(*_center(el["pt"]))
            return {"ok": True, "did": "click", "via": "cursor"}
        if x is not None and y is not None:
            fx, fy = seen["frame"][:2]
            cursor_click(fx + float(x) / seen["scale"], fy + float(y) / seen["scale"])
            return {"ok": True, "did": "click", "via": "cursor"}
        return {"ok": False, "error": "click needs an element or x/y"}
    if action == "fill":
        if el is None or not text:
            return {"ok": False, "error": "fill needs an element and text"}
        if el.get("ref") is not None and be.set_value(el["ref"], text):
            return {"ok": True, "did": "fill", "via": "uia"}
        if el.get("ref") is None or not be.focus(el["ref"]):
            cursor_click(*_center(el["pt"]))
        _front(be, hwnd)
        be.keys(["ctrl", "a"])
        be.type_text(text)
        _last_own[0] = time.monotonic()
        return {"ok": True, "did": "fill", "via": "keys"}
    if action == "key":
        combo = map_keys(keys or "")
        if not combo:
            return {"ok": False, "error": "key needs keys"}
        _front(be, hwnd)
        be.keys(combo)
        _last_own[0] = time.monotonic()
        return {"ok": True, "did": "key", "via": "keys"}
    if action == "scroll":
        if direction not in ("up", "down"):
            return {"ok": False, "error": "scroll needs direction up or down"}
        cx, cy = _center(el["pt"]) if el is not None else _center(seen["frame"])
        _front(be, hwnd)
        be.scroll_at(cx, cy, direction)
        _last_own[0] = time.monotonic()
        return {"ok": True, "did": "scroll", "via": "cursor"}
    if action == "open_app":
        if not app:
            return {"ok": False, "error": "open_app needs app"}
        res = be.open_app(app)
        # What really started ("Warzone" → "Call of Duty" through Battle.net): the window to look for.
        launched = str(res.get("launched") or "") if isinstance(res, dict) else ""
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and not be.find_window(launched or app):
            time.sleep(0.1)
        out = {"ok": True, "did": "open_app", "via": "app"}
        if launched:
            out["launched"] = launched
        return out
    if action == "open_url":
        if not str(url or "").startswith(("https://", "http://")):
            return {"ok": False, "error": "open_url needs an http(s) url"}
        be.open_url(url, app)
        time.sleep(0.8)
        return {"ok": True, "did": "open_url", "via": "app"}
    if action == "wait":
        time.sleep(0.5)
        return {"ok": True, "did": "wait", "via": ""}
    return {"ok": False, "error": f"unknown action {action!r}"}


def _clicks(elements, **kw) -> dict:
    """Press several numbered elements of one look in order; stop at the first that fails."""
    done, landed = 0, "unknown"
    for element in elements or []:
        res = do_action("click", element=element, **kw)
        if not res.get("ok"):
            return {**res, "did": "clicks", "done": done}
        done += 1
        landed = "no" if res.get("landed") == "no" else landed
    if not done:
        return {"ok": False, "error": "clicks needs elements", "did": "clicks", "done": 0}
    return {"ok": True, "did": "clicks", "via": "batch", "done": done, "landed": landed}


def do_and_look(action: str, *, look_after: bool = True, **kw) -> dict:
    with _act_lock:
        started = time.monotonic()
        with _looks_lock:
            lid = kw.get("look_id")
            before = _looks.get(lid) if lid else (next(reversed(_looks.values())) if _looks else None)
        elements = kw.pop("elements", None)
        try:
            res = _clicks(elements, **kw) if action == "clicks" else do_action(action, **kw)
        except Exception as exc:  # noqa: BLE001
            log.warning("ui_do %s failed", action, exc_info=True)
            res = {"ok": False, "error": str(exc)[:200] or type(exc).__name__}
        landed = res.get("landed") or "unknown"
        if res.get("ok") and look_after:
            if action == "open_app":
                res["look"] = read_window(app=kw.get("app"))
            else:
                if not (before and before.get("engine") == "agent-desktop"):
                    time.sleep(0.25)   # let the window repaint (agent-desktop waits for its own moves)
                res["look"] = read_window(app=before["app"] if before else None,
                                          surface=(before or {}).get("surface"))
            nxt = res["look"] if isinstance(res.get("look"), dict) else {}
            same_view = before and nxt.get("engine") == before.get("engine") \
                and nxt.get("surface") == before.get("surface")  # two engines' signatures never match
            if landed == "unknown" and same_view and nxt.get("sig") and nxt.get("sig") != before.get("sig"):
                landed = "yes"
        res["landed"] = landed
        res["ms"] = int((time.monotonic() - started) * 1000)
        return res


# ── the Windows backend ──────────────────────────────────────────────────────

class _WinBackend:
    """UI Automation (uiautomation), Win32 (ctypes) and pynput, used only on Windows."""

    def __init__(self) -> None:
        import uiautomation as auto   # noqa: F401
        self._auto = auto

    @staticmethod
    def _user32():
        import ctypes
        return ctypes.windll.user32

    def _proc_name(self, hwnd: int) -> str:
        import ctypes
        import os
        from ctypes import wintypes
        pid = wintypes.DWORD()
        self._user32().GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        try:
            import psutil
            return os.path.splitext(psutil.Process(pid.value).name())[0]
        except Exception:  # noqa: BLE001
            return ""

    def frontmost(self) -> tuple:
        hwnd = int(self._user32().GetForegroundWindow() or 0)
        return hwnd, self._proc_name(hwnd) if hwnd else ""

    def find_window(self, app: str):
        want = app.lower().removesuffix(".exe")
        from jc_client.skills.windows import list_windows
        for w in list_windows()["windows"]:
            if w["app"].lower() == want or want in w["title"].lower():
                return w["hwnd"], w["app"]
        return None

    def window_rect(self, hwnd: int) -> tuple:
        import ctypes
        from ctypes import wintypes
        r = wintypes.RECT()
        self._user32().GetWindowRect(hwnd, ctypes.byref(r))
        return (r.left, r.top, r.right - r.left, r.bottom - r.top)

    def title(self, hwnd: int) -> str:
        from jc_client.skills.windows import _get_window_title
        return _get_window_title(hwnd)

    def walk(self, hwnd: int, frame: tuple, max_elements: int, texts: list) -> list:
        auto = self._auto
        root = auto.ControlFromHandle(hwnd)
        out: list = []
        deadline = time.monotonic() + WALK_BUDGET_S
        seen = 0
        for ctrl, depth in auto.WalkControl(root, includeTop=False, maxDepth=MAX_DEPTH):
            seen += 1
            if seen > MAX_NODES or time.monotonic() > deadline or len(out) >= max_elements:
                break
            try:
                rect = ctrl.BoundingRectangle
                name = (ctrl.Name or "").strip()
                kind = ctrl.ControlTypeName
            except Exception:  # noqa: BLE001
                continue
            if kind == "TextControl" and name:
                texts.append(name)
            role = ax_role(kind)
            if role is None or rect.width() <= 2 or rect.height() <= 2 or ctrl.IsOffscreen:
                continue
            out.append({"role": role, "label": name[:120], "pt": (rect.left, rect.top, rect.width(), rect.height()),
                        "ref": ctrl})
        return out

    def capture(self, hwnd: int, frame: tuple):
        from PIL import ImageGrab
        x, y, w, h = frame
        return ImageGrab.grab(bbox=(x, y, x + w, y + h), all_screens=True)

    def invoke(self, ref) -> bool:
        try:
            pattern = ref.GetInvokePattern()
            if pattern:
                pattern.Invoke()
                return True
            toggle = ref.GetTogglePattern()
            if toggle:
                toggle.Toggle()
                return True
        except Exception:  # noqa: BLE001
            pass
        return False

    def set_value(self, ref, text: str) -> bool:
        try:
            pattern = ref.GetValuePattern()
            if pattern and not pattern.IsReadOnly:
                pattern.SetValue(text)
                return True
        except Exception:  # noqa: BLE001
            pass
        return False

    def focus(self, ref) -> bool:
        try:
            ref.SetFocus()
            return True
        except Exception:  # noqa: BLE001
            return False

    def activate(self, hwnd: int) -> None:
        u = self._user32()
        u.ShowWindow(hwnd, 9)
        u.SetForegroundWindow(hwnd)

    def idle_seconds(self) -> float:
        import ctypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]
        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(LASTINPUTINFO)
        ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info))
        tick = ctypes.windll.kernel32.GetTickCount
        tick.restype = ctypes.c_uint32   # unsigned: it wraps after ~49.7 days, signed after 24.9
        return ((tick() - info.dwTime) & 0xFFFFFFFF) / 1000.0

    def click(self, x: float, y: float, count: int = 1) -> None:
        from jc_client.skills.common import _mouse
        from pynput.mouse import Button
        _, m = _mouse()   # (Button, controller): the bare tuple crashed every cursor click (live)
        old = m.position
        m.position = (int(x), int(y))
        m.click(Button.left, count)
        m.position = old   # put the cursor back

    def keys(self, combo: list) -> None:
        from jc_client.skills.common import key_press
        key_press(combo)

    def type_text(self, text: str) -> None:
        from jc_client.skills.common import type_text
        type_text(text)

    def scroll_at(self, x: float, y: float, direction: str) -> None:
        from jc_client.skills.common import _mouse
        _, m = _mouse()
        old = m.position
        m.position = (int(x), int(y))
        m.scroll(0, 5 if direction == "up" else -5)
        m.position = old

    def open_app(self, name: str):
        from jc_client.skills.windows import open_app
        return open_app(name)

    def open_url(self, url: str, app: Optional[str] = None) -> None:
        # The browser he named (startfile with no default browser set pops Windows' app picker — live).
        if app:
            try:
                from jc_client.skills.windows import open_url_in
                open_url_in(url, app)
                return
            except Exception:  # noqa: BLE001
                log.warning("open_url in %s failed; the default browser instead", app, exc_info=True)
        import os
        os.startfile(url)   # type: ignore[attr-defined]


_BACKEND: Optional[_WinBackend] = None


def _backend():
    global _BACKEND
    if _BACKEND is None:
        _BACKEND = _WinBackend()
    return _BACKEND


# ── skills (Windows only; same names, schemas and results as skills/ui.py) ──

_UIA_POOL = None


def _on_uia_thread(fn, *args, **kw):
    """Every UI Automation call on ONE thread with COM set up (skills arrive on executor
    threads without COM, and UIA elements must stay on the thread that found them)."""
    global _UIA_POOL
    if _UIA_POOL is None:
        from concurrent.futures import ThreadPoolExecutor

        def init():
            try:
                import comtypes
                comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
            except Exception:  # noqa: BLE001
                log.debug("COM init on the UIA thread failed", exc_info=True)
        _UIA_POOL = ThreadPoolExecutor(max_workers=1, thread_name_prefix="uia", initializer=init)
    return _UIA_POOL.submit(fn, *args, **kw).result(timeout=60)


def _register() -> None:
    from jc_client.skills import skill

    @skill(
        "ui_look",
        "See the PC's frontmost (or named) app's window for fast computer control: a screenshot with numbered "
        "boxes and the same numbered elements (role, label). Pass the numbers and look_id to ui_do.",
        {"type": "object", "properties": {
            "app": {"type": "string", "description": "App or process name; default the frontmost app."},
            "max_elements": {"type": "integer", "default": 250},
            "surface": {"type": "string", "enum": SURFACES,
                        "description": "Read one surface instead of the window: the taskbar, tray, Start menu, "
                                       "Action Center, or an open menu / dialog sheet."},
        }},
    )
    def ui_look(app: str | None = None, max_elements: int = 250, surface: str | None = None) -> dict:
        return _on_uia_thread(read_window, app=app, max_elements=max_elements, surface=surface)

    @skill(
        "ui_do",
        "Do one move on the PC and return the next ui_look: click/fill a numbered element from a look, press "
        "keys (e.g. 'return', 'ctrl+f'), scroll up/down, open_app, or wait. UI Automation first; the real "
        "cursor only when needed (and put back).",
        {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["click", "fill", "key", "scroll", "open_app", "open_url", "wait",
                                                  "clicks"]},
            "elements": {"type": "array", "items": {"type": "integer"},
                         "description": "clicks: numbered elements of one look, pressed in order."},
            "url": {"type": "string", "description": "open_url: the page to open (default browser)."},
            "look_id": {"type": "string"},
            "element": {"type": "integer"},
            "text": {"type": "string"},
            "keys": {"type": "string"},
            "direction": {"type": "string", "enum": ["up", "down"]},
            "x": {"type": "number", "description": "Screenshot pixels (with look_id) when no element fits."},
            "y": {"type": "number"},
            "app": {"type": "string"},
            "look": {"type": "boolean", "default": True},
        }, "required": ["action"]},
        destructive=True,
    )
    def ui_do(action: str, look_id: str | None = None, element: int | None = None, text: str | None = None,
              keys: str | None = None, direction: str | None = None, x: float | None = None, y: float | None = None,
              app: str | None = None, look: bool = True, url: str | None = None,
              elements: list | None = None) -> dict:
        if action == "clicks":
            return _on_uia_thread(do_and_look, action, look_after=look, look_id=look_id, elements=elements)
        return _on_uia_thread(do_and_look, action, look_after=look, look_id=look_id, element=element, text=text,
                              keys=keys, direction=direction, x=x, y=y, app=app, url=url)


if sys.platform == "win32":
    _register()
