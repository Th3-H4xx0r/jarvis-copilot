"""Fast computer control for the server's decision-model loop (macOS).

``ui_look`` returns one window as a screenshot with numbered boxes plus the
same numbered elements, read from the accessibility tree (Apple's text
recognition stands in when an app exposes almost nothing). ``ui_do`` acts on a
numbered element — accessibility first (press, set value: the cursor never
moves), the real cursor/keyboard only when that can't work — and returns the
next ``ui_look`` in the same reply, so each move is one round trip.
"""
from __future__ import annotations

import base64
import hashlib
import io
import logging
import subprocess
import threading
import time
import uuid
from collections import OrderedDict
from typing import Any

from jc_client.skills import skill

log = logging.getLogger("jc_client.skills.ui")

ACTIONABLE = frozenset({
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
    "AXSearchField", "AXSecureTextField", "AXComboBox", "AXLink", "AXSlider", "AXIncrementor",
    "AXDisclosureTriangle", "AXMenuItem", "AXCell", "AXRow", "AXTab", "AXSegmentedControl", "AXColorWell",
    "AXDateField", "AXStepper", "AXSwitch", "AXToggle",
})
_ATTRS = ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXPosition", "AXSize",
          "AXChildren", "AXEnabled", "AXSubrole", "AXHelp"]
_TEXT_ATTRS = ["AXRole", "AXValue", "AXTitle", "AXDescription", "AXChildren"]
WALK_BUDGET_S = 0.45
MAX_NODES = 4000
MAX_DEPTH = 30
OCR_BELOW = 5
TEXT_CAP = 6000
_KEEP_LOOKS = 4
_NOT_TRUSTED = ("Turn on Accessibility for the JarvisCopilot Mac app: System Settings → Privacy & Security → "
                "Accessibility → enable the jc-client Python, then restart jc-client.")

_looks: "OrderedDict[str, dict]" = OrderedDict()
_looks_lock = threading.Lock()
_enabled_pids: set = set()


# ── accessibility adapter (tests swap it) ────────────────────────────────────

class _MacAX:
    """The few AX / AppKit calls this module needs."""

    def __init__(self):
        import ApplicationServices as AS
        self.AS = AS

    def trusted(self) -> bool:
        return bool(self.AS.AXIsProcessTrusted())

    # NSWorkspace's app list and frontmost app go stale in this long-running
    # process (nothing pumps a main run loop): a just-launched app read as "not
    # running" and the frontmost app never changed. The window server's list is live.
    def frontmost(self) -> tuple:
        for w in _window_list(True):
            if int(w.get("kCGWindowLayer", 1)) == 0:
                return int(w["kCGWindowOwnerPID"]), str(w.get("kCGWindowOwnerName") or "")
        return 0, ""

    def find_app(self, name: str):
        want = name.strip().lower()
        for w in _window_list(False):
            owner = str(w.get("kCGWindowOwnerName") or "")
            if owner.lower() == want and int(w.get("kCGWindowLayer", 1)) == 0:
                return int(w["kCGWindowOwnerPID"]), owner
        if "." in want:  # a bundle id
            from AppKit import NSRunningApplication
            for app in NSRunningApplication.runningApplicationsWithBundleIdentifier_(name.strip()) or []:
                return int(app.processIdentifier()), str(app.localizedName() or name)
        return None

    def app_name(self, pid: int):
        for w in _window_list(False):
            if int(w.get("kCGWindowOwnerPID", -1)) == pid:
                return str(w.get("kCGWindowOwnerName") or "")
        return None

    def activate(self, pid: int) -> None:
        from AppKit import NSRunningApplication
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        if app is not None:
            app.activateWithOptions_(1 << 1)  # NSApplicationActivateIgnoringOtherApps

    def app_element(self, pid: int):
        el = self.AS.AXUIElementCreateApplication(pid)
        self.AS.AXUIElementSetMessagingTimeout(el, 0.5)
        if pid not in _enabled_pids:
            # Electron / Chromium apps only expose web content to accessibility when asked.
            self.AS.AXUIElementSetAttributeValue(el, "AXManualAccessibility", True)
            _enabled_pids.add(pid)
        return el

    def window(self, app_el):
        err, win = self.AS.AXUIElementCopyAttributeValue(app_el, "AXFocusedWindow", None)
        if err != 0 or win is None:
            err, wins = self.AS.AXUIElementCopyAttributeValue(app_el, "AXWindows", None)
            win = wins[0] if err == 0 and wins else None
        return win

    def _plain(self, v):
        AS = self.AS
        if v is None:
            return None
        if type(v).__name__ == "AXValueRef":
            t = AS.AXValueGetType(v)
            if t == AS.kAXValueCGPointType:
                ok, p = AS.AXValueGetValue(v, t, None)
                return (float(p.x), float(p.y)) if ok else None
            if t == AS.kAXValueCGSizeType:
                ok, s = AS.AXValueGetValue(v, t, None)
                return (float(s.width), float(s.height)) if ok else None
            return None  # an AXError slot: the attribute is missing
        return v

    def attrs(self, el, names) -> dict:
        err, vals = self.AS.AXUIElementCopyMultipleAttributeValues(el, names, 0, None)
        if err != 0 or vals is None:
            return {}
        return {n: self._plain(v) for n, v in zip(names, vals)}

    def actions(self, el) -> list:
        err, names = self.AS.AXUIElementCopyActionNames(el, None)
        return list(names or []) if err == 0 else []

    def press(self, el) -> bool:
        return self.AS.AXUIElementPerformAction(el, "AXPress") == 0

    def set_value(self, el, text: str) -> bool:
        self.AS.AXUIElementSetAttributeValue(el, "AXFocused", True)
        if self.AS.AXUIElementSetAttributeValue(el, "AXValue", text) != 0:
            return False
        got = self.attrs(el, ["AXValue"]).get("AXValue")
        return str(got or "") == text

    def focus(self, el) -> bool:
        return self.AS.AXUIElementSetAttributeValue(el, "AXFocused", True) == 0


def _window_list(on_screen: bool) -> list:
    """The window server's windows, front to back (live, unlike NSWorkspace here)."""
    from Quartz import (CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowListExcludeDesktopElements,
                        kCGWindowListOptionAll, kCGWindowListOptionOnScreenOnly)
    opt = (kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements) if on_screen \
        else kCGWindowListOptionAll
    return list(CGWindowListCopyWindowInfo(opt, kCGNullWindowID) or [])


_ax_impl: Any = None


def _ax():
    global _ax_impl
    if _ax_impl is None:
        _ax_impl = _MacAX()
    return _ax_impl


# ── reading the window ───────────────────────────────────────────────────────

def _inner_text(ax, el, depth=0) -> str:
    """The first text inside an unlabelled row/cell/button (Finder's "Downloads" row)."""
    if depth > 2:
        return ""
    a = ax.attrs(el, _TEXT_ATTRS)
    if depth and a.get("AXRole") in ("AXStaticText", "AXTextField", "AXImage"):
        for k in ("AXValue", "AXTitle", "AXDescription"):
            if isinstance(a.get(k), str) and a[k].strip():
                return " ".join(a[k].split())[:80]
    for child in (a.get("AXChildren") or [])[:4]:
        t = _inner_text(ax, child, depth + 1)
        if t:
            return t
    return ""


def _label(a: dict) -> str:
    for key in ("AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXHelp"):
        v = a.get(key)
        if isinstance(v, (str, int, float)) and not isinstance(v, bool) and str(v).strip():
            return " ".join(str(v).split())[:80]
    return ""


def _subrole_label(a: dict) -> str:
    sub = str(a.get("AXSubrole") or "")
    if sub.startswith("AX") and sub not in ("AXStandardWindow", "AXUnknown"):
        # Unlabelled window controls: AXCloseButton → "close button".
        import re
        return re.sub(r"(?<!^)(?=[A-Z])", " ", sub[2:]).lower()
    return ""


def walk(ax, window, frame, max_elements: int, texts: list | None = None) -> list:
    """Actionable elements inside ``frame`` (x, y, w, h in points), breadth first.
    ``texts`` (when given) also collects the static text values: a display's
    "84" isn't clickable, but it changing means the screen changed."""
    wx, wy, ww, wh = frame
    out, queue, seen = [], [(window, 0)], 0
    deadline = time.monotonic() + WALK_BUDGET_S
    while queue and len(out) < max_elements and seen < MAX_NODES and time.monotonic() < deadline:
        el, depth = queue.pop(0)
        seen += 1
        a = ax.attrs(el, _ATTRS)
        role = str(a.get("AXRole") or "")
        pos, size = a.get("AXPosition"), a.get("AXSize")
        if role in ACTIONABLE and pos and size and a.get("AXEnabled") is not False:
            x, y = pos
            w, h = size
            x0, y0 = max(x, wx), max(y, wy)
            x1, y1 = min(x + w, wx + ww), min(y + h, wy + wh)
            if x1 - x0 > 2 and y1 - y0 > 2:
                label = _label(a) or _inner_text(ax, el) or _subrole_label(a)
                out.append({"role": role, "label": label, "pt": (x0, y0, x1 - x0, y1 - y0), "ref": el})
        elif texts is not None and role in ("AXStaticText", "AXHeading"):
            t = next((str(a[k]) for k in ("AXValue", "AXTitle", "AXDescription")
                      if isinstance(a.get(k), (str, int, float)) and str(a.get(k)).strip()), "")
            if t:
                texts.append(t[:200])
        if depth < MAX_DEPTH:
            queue.extend((c, depth + 1) for c in (a.get("AXChildren") or []))
    return out


def _sig(title: str, elements: list, texts: list) -> str:
    h = hashlib.sha1(title.encode())
    for e in elements:
        h.update(f"{e['role']}|{e['label']}|{[round(v) for v in e['pt']]}".encode())
    for t in texts:
        h.update(f"t|{t}".encode())
    return h.hexdigest()[:16]


def quick_sig_of(ax, window, max_elements: int = 150) -> str:
    """The screen signature without a screenshot (for settling after a move)."""
    wa = ax.attrs(window, ["AXTitle", "AXPosition", "AXSize"])
    if not wa.get("AXPosition") or not wa.get("AXSize"):
        return ""
    texts: list = []
    elements = walk(ax, window, (*wa["AXPosition"], *wa["AXSize"]), max_elements, texts)
    return _sig(str(wa.get("AXTitle") or ""), elements, texts)


def quick_sig(ax, pid: int) -> str:
    win = ax.window(ax.app_element(pid))
    return quick_sig_of(ax, win) if win is not None else ""


SETTLE_BUDGET_S = 0.5
SETTLE_STEP_S = 0.06


def settle(ax, pid: int, before_sig: str) -> None:
    """Wait (≤ SETTLE_BUDGET_S) until the screen differs from ``before_sig``."""
    deadline = time.monotonic() + SETTLE_BUDGET_S
    while True:
        time.sleep(SETTLE_STEP_S)
        if quick_sig(ax, pid) != before_sig or time.monotonic() >= deadline:
            return


def _window_id(pid: int, frame) -> int | None:
    """The CG window number of ``pid``'s window at ``frame`` (so a covered window still captures)."""
    try:
        from Quartz import CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowListOptionAll
        best = None
        for w in CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID) or []:
            if int(w.get("kCGWindowOwnerPID", -1)) != pid or int(w.get("kCGWindowLayer", 1)) != 0:
                continue
            b = w.get("kCGWindowBounds") or {}
            d = sum(abs(float(b.get(k, 0)) - v) for k, v in zip(("X", "Y", "Width", "Height"), frame))
            if best is None or d < best[0]:
                best = (d, int(w["kCGWindowNumber"]))
        return best[1] if best and best[0] < 8 else None
    except Exception:
        return None


def _capture(frame, pid=None):
    """(PIL image, CGImage) of ``pid``'s window at ``frame`` (points), else that screen rect."""
    from Quartz import (CGDataProviderCopyData, CGImageGetBytesPerRow, CGImageGetDataProvider, CGImageGetHeight,
                        CGImageGetWidth, CGRectMake, CGRectNull, CGWindowListCreateImage, kCGNullWindowID,
                        kCGWindowImageBoundsIgnoreFraming, kCGWindowImageDefault,
                        kCGWindowListOptionIncludingWindow, kCGWindowListOptionOnScreenOnly)
    from PIL import Image
    wid = _window_id(pid, frame) if pid else None
    if wid:
        cg = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, wid,
                                     kCGWindowImageBoundsIgnoreFraming)
    else:
        cg = CGWindowListCreateImage(CGRectMake(*[float(v) for v in frame]), kCGWindowListOptionOnScreenOnly,
                                     kCGNullWindowID, kCGWindowImageDefault)
    if cg is None:
        raise RuntimeError("Screen capture failed: turn on Screen Recording for the jc-client Python.")
    w, h, bpr = int(CGImageGetWidth(cg)), int(CGImageGetHeight(cg)), int(CGImageGetBytesPerRow(cg))
    data = CGDataProviderCopyData(CGImageGetDataProvider(cg))
    return Image.frombuffer("RGBA", (w, h), bytes(data), "raw", "BGRA", bpr, 1).convert("RGB"), cg


def _ocr(cg, frame) -> list:
    """Text boxes from Apple's on-device recognition, as elements (points)."""
    try:
        import Vision
    except Exception:
        log.info("ui_look: pyobjc-framework-Vision missing; no text fallback")
        return []
    req = Vision.VNRecognizeTextRequest.alloc().init()
    req.setRecognitionLevel_(1)  # fast
    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(cg, None)
    ok = handler.performRequests_error_([req], None)
    if isinstance(ok, tuple):
        ok = ok[0]
    if not ok:
        return []
    wx, wy, ww, wh = frame
    out = []
    for obs in req.results() or []:
        cands = obs.topCandidates_(1)
        if not cands:
            continue
        b = obs.boundingBox()  # normalised, origin bottom-left
        x, y = wx + b.origin.x * ww, wy + (1 - b.origin.y - b.size.height) * wh
        out.append({"role": "text", "label": str(cands[0].string())[:80],
                    "pt": (x, y, b.size.width * ww, b.size.height * wh), "ref": None})
    return out


def _draw(img, elements):
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


def read_window(app: str | None = None, max_elements: int = 150, width: int = 1024, ax=None,
                capture=None, pid: int | None = None) -> dict:
    """Read ``app`` (or the app with ``pid``, or the frontmost app)."""
    ax = ax or _ax()
    capture = capture or _capture
    started = time.monotonic()
    if not ax.trusted():
        return {"ok": False, "error": _NOT_TRUSTED}
    if pid:
        name = ax.app_name(pid)
        if name is None:
            return {"ok": False, "error": "That app has quit."}
    elif app:
        found = ax.find_app(app)
        if not found:
            return {"ok": False, "error": f"{app} isn't running. Open it first (open_app)."}
        pid, name = found
    else:
        pid, name = ax.frontmost()
    app_el = ax.app_element(pid)
    win = ax.window(app_el)
    if win is None:
        return {"ok": False, "error": f"{name} has no open window."}
    wa = ax.attrs(win, ["AXTitle", "AXPosition", "AXSize"])
    if not wa.get("AXPosition") or not wa.get("AXSize"):
        return {"ok": False, "error": f"Could not read {name}'s window."}
    frame = (*wa["AXPosition"], *wa["AXSize"])
    max_elements = max(1, min(int(max_elements or 150), 400))
    texts: list = []
    elements = walk(ax, win, frame, max_elements, texts)
    title = str(wa.get("AXTitle") or "")
    sig = _sig(title, elements, texts)  # the same signature settle() polls
    img, cg = capture(frame, pid)
    source = "ax"
    if len(elements) < OCR_BELOW:
        found = _ocr(cg, frame) if cg is not None else []
        if found:
            elements, source = (elements + found)[:max_elements], "ocr"
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
    img.save(buf, format="JPEG", quality=70)
    look_id = uuid.uuid4().hex[:10]
    with _looks_lock:
        _looks[look_id] = {"pid": pid, "app": name, "frame": frame, "scale": scale, "elements": elements,
                           "sig": sig}
        while len(_looks) > _KEEP_LOOKS:
            _looks.popitem(last=False)
    return {"ok": True, "look_id": look_id, "app": name, "window": title[:120], "width": img.width,
            "height": img.height, "origin": list(frame[:2]), "scale": round(scale, 4),
            "base64": base64.b64encode(buf.getvalue()).decode("ascii"), "mime": "image/jpeg",
            "elements": [{"i": e["i"], "role": e["role"], "label": e["label"], "box": e["box"]} for e in elements],
            "source": source, "sig": sig, "ms": int((time.monotonic() - started) * 1000),
            # The window's text from accessibility: readable even under a banner or popup.
            "text": "\n".join(t for t in texts if t.strip())[:TEXT_CAP]}


# ── acting ───────────────────────────────────────────────────────────────────

def _pointer():
    from jc_client.skills.common import _mouse
    return _mouse()


class NotInFront(Exception):
    """The app a move is for can't be brought in front (he is using another one)."""


class UserBusy(NotInFront):
    """He is typing or clicking on the Mac right now."""


USER_WAIT_S = 1.5
_last_own = [0.0]  # monotonic time of our last real key/cursor event


def _user_idle_s() -> float:
    from Quartz import CGEventSourceSecondsSinceLastEventType, kCGAnyInputEventType, kCGEventSourceStateHIDSystemState
    return float(CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType))


def _wait_for_user():
    """Real keys/clicks only when his last input is older than ours: if he is typing,
    clicking or in Spotlight, wait a moment, then refuse rather than take over."""
    deadline = time.monotonic() + USER_WAIT_S
    while True:
        idle = _user_idle_s()
        if idle >= 0.8 or idle >= (time.monotonic() - _last_own[0]) - 0.05:
            return
        if time.monotonic() >= deadline:
            raise UserBusy()
        time.sleep(0.1)


def _front(ax, pid):
    """Bring ``pid`` in front before any real cursor or key event, or refuse: a
    key or click must never land in the app the user is working in."""
    _wait_for_user()
    if not pid or ax.frontmost()[0] == pid:
        return
    ax.activate(pid)
    deadline = time.monotonic() + 0.5
    while ax.frontmost()[0] != pid:
        if time.monotonic() >= deadline:
            raise NotInFront()
        time.sleep(0.05)


def _cursor_click(ax, pid, x, y, count=1):
    """Click screen point (x, y) like a person, then put the cursor back."""
    _front(ax, pid)
    Button, mouse = _pointer()
    old = mouse.position
    mouse.position = (x, y)
    time.sleep(0.03)
    mouse.click(Button.left, count)
    _last_own[0] = time.monotonic()
    time.sleep(0.03)
    mouse.position = old


def _keys(ax, pid, keys: str):
    from jc_client.skills.common import key_press
    _front(ax, pid)
    key_press([k.strip() for k in str(keys).split("+") if k.strip()])
    _last_own[0] = time.monotonic()


def _type(ax, pid, text: str, chunk: int = 8):
    """Type in short bursts, checking the app is still in front before each one."""
    from jc_client.skills import common
    for i in range(0, len(text), chunk):
        if ax.frontmost()[0] != pid:
            raise NotInFront()
        common.type_text(text[i:i + chunk])
        _last_own[0] = time.monotonic()


def _scroll(ax, pid, x, y, direction):
    _front(ax, pid)
    _, mouse = _pointer()
    old = mouse.position
    mouse.position = (x, y)
    mouse.scroll(0, -5 if direction == "down" else 5)
    _last_own[0] = time.monotonic()
    time.sleep(0.05)
    mouse.position = old


def _center(pt):
    x, y, w, h = pt
    return x + w / 2, y + h / 2


def _open_app(name: str) -> None:
    subprocess.run(["open", "-a", name], check=True, timeout=15)


def _open(args: list) -> None:
    subprocess.run(["open", *args], check=True, timeout=15)


def _title_of(ax, app: str) -> str:
    found = ax.find_app(app)
    win = ax.window(ax.app_element(found[0])) if found else None
    return str((ax.attrs(win, ["AXTitle"]) if win is not None else {}).get("AXTitle") or "")


def do_action(action: str, look_id: str | None = None, element: int | None = None, text: str | None = None,
              keys: str | None = None, direction: str | None = None, x: float | None = None,
              y: float | None = None, app: str | None = None, ax=None, url: str | None = None) -> dict:
    """Do one move; returns ``{ok, did, via}`` or ``{ok: False, error}``."""
    ax = ax or _ax()
    if not ax.trusted():
        return {"ok": False, "error": _NOT_TRUSTED}
    try:
        return _do(ax, action, look_id, element, text, keys, direction, x, y, app, url)
    except UserBusy:
        return {"ok": False, "error": "You're using the Mac right now, so I won't type or move the cursor; "
                                      "only buttons can be pressed in the background."}
    except NotInFront:
        with _looks_lock:
            seen = _looks.get(look_id or "")
        name = (seen or {}).get("app") or "That app"
        return {"ok": False, "error": f"{name} isn't in front (another app is in use), so I won't type or move "
                                      "the cursor; only its buttons can be pressed in the background."}


def _do(ax, action, look_id, element, text, keys, direction, x, y, app, url=None) -> dict:
    with _looks_lock:
        # No look_id: the latest look (a model calling ui_do by hand often leaves it out).
        seen = _looks.get(look_id) if look_id else (next(reversed(_looks.values())) if _looks else None)
    if seen is None and (action in ("fill", "key", "scroll")
                         or (action == "click" and (element is not None or x is not None))):
        # Keys need to know which app they are for: never guess the frontmost one.
        return {"ok": False, "error": "That screen is gone; look again."}
    pid = seen["pid"] if seen else ax.frontmost()[0]
    el = None
    if element is not None and seen is not None:
        el = next((e for e in seen["elements"] if e["i"] == int(element)), None)
        if el is None:
            return {"ok": False, "error": f"There is no element {element} on that screen; look again."}

    if action == "click":
        if el is not None:
            if el.get("ref") is not None and "AXPress" in ax.actions(el["ref"]) and ax.press(el["ref"]):
                return {"ok": True, "did": "click", "via": "ax"}
            _cursor_click(ax, pid, *_center(el["pt"]))
            return {"ok": True, "did": "click", "via": "cursor"}
        if x is not None and y is not None:
            fx, fy = seen["frame"][:2]
            _cursor_click(ax, pid, fx + float(x) / seen["scale"], fy + float(y) / seen["scale"])
            return {"ok": True, "did": "click", "via": "cursor"}
        return {"ok": False, "error": "click needs an element or x/y"}
    if action == "fill":
        if el is None or not text:
            return {"ok": False, "error": "fill needs an element and text"}
        if el.get("ref") is not None and ax.set_value(el["ref"], text):
            return {"ok": True, "did": "fill", "via": "ax"}
        if el.get("ref") is None or not ax.focus(el["ref"]):
            _cursor_click(ax, pid, *_center(el["pt"]))
        _keys(ax, pid, "cmd+a")
        _type(ax, pid, text)
        return {"ok": True, "did": "fill", "via": "keys"}
    if action == "key":
        if not str(keys or "").strip():
            return {"ok": False, "error": "key needs keys"}
        _keys(ax, pid, keys)
        return {"ok": True, "did": "key", "via": "keys"}
    if action == "scroll":
        if direction not in ("up", "down"):
            return {"ok": False, "error": "scroll needs direction up or down"}
        if el is not None:
            cx, cy = _center(el["pt"])
        elif seen is not None:
            cx, cy = _center(seen["frame"])
        else:
            return {"ok": False, "error": "That screen is gone; look again."}
        _scroll(ax, pid, cx, cy, direction)
        return {"ok": True, "did": "scroll", "via": "cursor"}
    if action == "open_app":
        if not app:
            return {"ok": False, "error": "open_app needs app"}
        _open_app(app)
        # Its window is all the next look needs; it may not come in front (a
        # fullscreen app on another Space), and presses work in the background.
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            found = ax.find_app(app)
            if found and ax.window(ax.app_element(found[0])) is not None:
                break
            time.sleep(0.1)
        return {"ok": True, "did": "open_app", "via": "app"}
    if action == "open_url":
        # Straight to the page (a search results URL skips typing and a page load).
        if not str(url or "").startswith(("https://", "http://")):
            return {"ok": False, "error": "open_url needs an http(s) url"}
        browser = app or "Safari"
        before = _title_of(ax, browser)
        _open(["-a", browser, url])
        started = time.monotonic()
        deadline, last, steady = started + 6.0, None, 0
        while time.monotonic() < deadline:
            title = _title_of(ax, browser)
            # A new title that held for two reads; or, after 1.5 s, the same title
            # (the browser was already on that page).
            changed = title != before or time.monotonic() - started > 1.5
            steady = steady + 1 if (title and changed and title == last) else 0
            if steady >= 2:  # the new page's title held for two reads: loaded enough to read
                break
            last = title
            time.sleep(0.15)
        return {"ok": True, "did": "open_url", "via": "app"}
    if action == "wait":
        time.sleep(0.5)
        return {"ok": True, "did": "wait", "via": ""}
    return {"ok": False, "error": f"unknown action {action!r}"}


_act_lock = threading.Lock()  # one move on the Mac at a time, whoever asks


def do_and_look(action: str, *, look_after: bool = True, reader=None, **kw) -> dict:
    """One move, then (unless ``look_after`` is off) the next screen of the same
    app, read as soon as it differs from the screen the move was made on."""
    with _act_lock:
        return _do_and_look(action, look_after=look_after, reader=reader, **kw)


def _do_and_look(action: str, *, look_after: bool, reader, **kw) -> dict:
    reader = reader or read_window
    started = time.monotonic()
    with _looks_lock:
        lid = kw.get("look_id")
        before = _looks.get(lid) if lid else (next(reversed(_looks.values())) if _looks else None)
    try:
        res = do_action(action, **kw)
    except Exception as exc:
        log.warning("ui_do %s failed", action, exc_info=True)
        res = {"ok": False, "error": str(exc)[:200] or type(exc).__name__}
    if res.get("ok") and look_after:
        # Keep looking at the app the move was made in (it may sit behind other
        # windows: accessibility presses don't bring it forward); a new app → frontmost.
        if action in ("open_app", "open_url"):
            target = {"app": kw.get("app") or ("Safari" if action == "open_url" else None)}
        elif before:
            target = {"pid": before["pid"]}
            try:
                settle(_ax(), before["pid"], before["sig"])
            except Exception:
                log.debug("ui_do: settle failed", exc_info=True)
        else:
            target = {}
        res["look"] = reader(**target)
    res["ms"] = int((time.monotonic() - started) * 1000)
    return res


# ── skills ───────────────────────────────────────────────────────────────────

@skill(
    "ui_look",
    "See the frontmost (or named) app's window for fast computer control: a screenshot with numbered boxes "
    "and the same numbered elements (role, label). Pass the numbers and look_id to ui_do.",
    {"type": "object", "properties": {
        "app": {"type": "string", "description": "App name or bundle id; default the frontmost app."},
        "max_elements": {"type": "integer", "default": 150},
    }},
)
def ui_look(app: str | None = None, max_elements: int = 150) -> dict:
    return read_window(app=app, max_elements=max_elements)


@skill(
    "ui_do",
    "Do one move on the Mac and return the next ui_look: click/fill a numbered element from a look, press "
    "keys (e.g. 'return', 'cmd+f'), scroll up/down, open_app, or wait. Accessibility first; the real cursor "
    "only when needed (and put back).",
    {"type": "object", "properties": {
        "action": {"type": "string", "enum": ["click", "fill", "key", "scroll", "open_app", "open_url", "wait"]},
        "url": {"type": "string", "description": "open_url: the page to open (default browser Safari)."},
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
          app: str | None = None, look: bool = True, url: str | None = None) -> dict:
    return do_and_look(action, look_after=look, look_id=look_id, element=element, text=text, keys=keys,
                       direction=direction, x=x, y=y, app=app, url=url)
