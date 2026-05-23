"""Cross-platform skills.

Everything here runs unchanged on macOS, Windows, and Linux. Per-OS
quirks (osascript / PowerShell / xdotool) live in the matching
platform module.

Heavy deps are imported lazily inside each function so the registry can
be loaded even when pynput / pyperclip / Pillow aren't installed yet
(the installer pulls them in, but `jc-client status` shouldn't blow up
on a fresh checkout).
"""
from __future__ import annotations

import base64
import io
import logging
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import webbrowser
from typing import Any

from jc_client.skills import skill

log = logging.getLogger(__name__)


# ── URLs / system info ─────────────────────────────────────────────────────


@skill(
    "open_url",
    "Open a URL in the default browser.",
    {
        "type": "object",
        "properties": {"url": {"type": "string", "description": "Absolute URL"}},
        "required": ["url"],
    },
)
def open_url(url: str) -> dict:
    if not url or "://" not in url:
        raise ValueError("url must be absolute (include scheme)")
    webbrowser.open(url, new=2)
    return {"ok": True, "url": url}


@skill(
    "system_info",
    "Report basic info about this machine: OS, hostname, arch.",
    {"type": "object"},
)
def system_info() -> dict:
    import socket as _socket

    return {
        "hostname": _socket.gethostname(),
        "system": platform.system(),
        "release": platform.release(),
        "version": platform.version(),
        "machine": platform.machine(),
        "python": sys.version.split()[0],
    }


# ── Clipboard ──────────────────────────────────────────────────────────────


def _pyperclip():
    """Lazy-import pyperclip with a friendly error."""
    try:
        import pyperclip  # type: ignore
        return pyperclip
    except Exception as exc:
        raise RuntimeError(
            "clipboard skills need `pyperclip` (pip install pyperclip)"
        ) from exc


@skill(
    "clipboard_read",
    "Read the system clipboard as text.",
    {"type": "object"},
)
def clipboard_read() -> dict:
    text = _pyperclip().paste() or ""
    return {"text": text, "length": len(text)}


@skill(
    "clipboard_write",
    "Replace the system clipboard with the given text.",
    {
        "type": "object",
        "properties": {"text": {"type": "string"}},
        "required": ["text"],
    },
    destructive=True,
)
def clipboard_write(text: str) -> dict:
    _pyperclip().copy(text)
    return {"ok": True, "length": len(text)}


# ── Mouse ──────────────────────────────────────────────────────────────────


def _mouse():
    """Lazy-import pynput.mouse.Controller."""
    try:
        from pynput.mouse import Button, Controller  # type: ignore
        return Button, Controller()
    except Exception as exc:
        raise RuntimeError(
            "mouse skills need `pynput` (pip install pynput). "
            "On Linux you may also need `xdotool` for non-X11 / Wayland setups."
        ) from exc


_MOUSE_BUTTON_ALIASES = {
    "left": "left",
    "l": "left",
    "primary": "left",
    "right": "right",
    "r": "right",
    "secondary": "right",
    "middle": "middle",
    "m": "middle",
    "wheel": "middle",
}


def _resolve_button(name: str):
    Button, _ = _mouse()
    key = (name or "left").strip().lower()
    canonical = _MOUSE_BUTTON_ALIASES.get(key, key)
    btn = getattr(Button, canonical, None)
    if btn is None:
        raise ValueError(
            f"unknown mouse button: {name!r} (expected left/right/middle)"
        )
    return btn


@skill(
    "mouse_position",
    "Return the current mouse cursor position as {x, y}.",
    {"type": "object"},
)
def mouse_position() -> dict:
    _, m = _mouse()
    x, y = m.position
    return {"x": int(x), "y": int(y)}


@skill(
    "mouse_move",
    "Move the cursor to absolute screen coordinates (x, y). With "
    "`relative=true`, treat x/y as a delta from the current position.",
    {
        "type": "object",
        "properties": {
            "x": {"type": "number"},
            "y": {"type": "number"},
            "relative": {"type": "boolean", "default": False},
            "duration": {
                "type": "number",
                "description": "Seconds to animate over (0 = teleport).",
                "default": 0,
            },
        },
        "required": ["x", "y"],
    },
)
def mouse_move(x: float, y: float, relative: bool = False, duration: float = 0) -> dict:
    _, m = _mouse()
    tx, ty = (int(x), int(y))
    if relative:
        cx, cy = m.position
        tx, ty = int(cx) + tx, int(cy) + ty
    if duration <= 0:
        m.position = (tx, ty)
    else:
        # Linear animation in ~30 steps/sec. pynput's `move()` is
        # relative; we step from current toward (tx, ty).
        steps = max(2, int(duration * 60))
        cx, cy = m.position
        for i in range(1, steps + 1):
            frac = i / steps
            m.position = (
                int(cx + (tx - cx) * frac),
                int(cy + (ty - cy) * frac),
            )
            time.sleep(duration / steps)
    return {"ok": True, "x": tx, "y": ty}


@skill(
    "mouse_click",
    "Click the mouse. Without x/y, clicks where the cursor currently is. "
    "`button` is left/right/middle. `count` allows double-click etc.",
    {
        "type": "object",
        "properties": {
            "x": {"type": "number"},
            "y": {"type": "number"},
            "button": {"type": "string", "default": "left"},
            "count": {"type": "integer", "default": 1, "minimum": 1, "maximum": 10},
        },
    },
    destructive=True,
)
def mouse_click(
    x: float | None = None,
    y: float | None = None,
    button: str = "left",
    count: int = 1,
) -> dict:
    _, m = _mouse()
    btn = _resolve_button(button)
    if x is not None and y is not None:
        m.position = (int(x), int(y))
    m.click(btn, max(1, int(count)))
    return {"ok": True, "x": int(m.position[0]), "y": int(m.position[1]), "button": button}


@skill(
    "mouse_scroll",
    "Scroll the mouse wheel. `dy` positive scrolls up, negative scrolls "
    "down. `dx` is horizontal wheel (mostly Mac trackpads).",
    {
        "type": "object",
        "properties": {
            "dx": {"type": "number", "default": 0},
            "dy": {"type": "number", "default": 0},
        },
    },
)
def mouse_scroll(dx: float = 0, dy: float = 0) -> dict:
    _, m = _mouse()
    m.scroll(int(dx), int(dy))
    return {"ok": True}


@skill(
    "mouse_drag",
    "Press the mouse button at (x1,y1), move to (x2,y2), then release. "
    "Useful for dragging a window or selecting text.",
    {
        "type": "object",
        "properties": {
            "x1": {"type": "number"},
            "y1": {"type": "number"},
            "x2": {"type": "number"},
            "y2": {"type": "number"},
            "button": {"type": "string", "default": "left"},
            "duration": {"type": "number", "default": 0.2},
        },
        "required": ["x1", "y1", "x2", "y2"],
    },
    destructive=True,
)
def mouse_drag(
    x1: float, y1: float, x2: float, y2: float, button: str = "left", duration: float = 0.2
) -> dict:
    Button, m = _mouse()
    btn = _resolve_button(button)
    m.position = (int(x1), int(y1))
    m.press(btn)
    try:
        if duration <= 0:
            m.position = (int(x2), int(y2))
        else:
            steps = max(2, int(duration * 60))
            for i in range(1, steps + 1):
                frac = i / steps
                m.position = (
                    int(x1 + (x2 - x1) * frac),
                    int(y1 + (y2 - y1) * frac),
                )
                time.sleep(duration / steps)
    finally:
        m.release(btn)
    return {"ok": True}


# ── Keyboard ───────────────────────────────────────────────────────────────


def _keyboard():
    try:
        from pynput.keyboard import Controller, Key, KeyCode  # type: ignore
        return Controller(), Key, KeyCode
    except Exception as exc:
        raise RuntimeError(
            "keyboard skills need `pynput` (pip install pynput)."
        ) from exc


# Map shorthand names → pynput.Key members. The agent will use these
# strings in its key_press args so we keep the alias table close to
# what people actually type.
_KEY_ALIASES = {
    "enter": "enter", "return": "enter", "ret": "enter",
    "space": "space", "spc": "space",
    "tab": "tab",
    "esc": "esc", "escape": "esc",
    "backspace": "backspace", "bksp": "backspace",
    "delete": "delete", "del": "delete",
    "shift": "shift", "ctrl": "ctrl", "control": "ctrl",
    "alt": "alt", "option": "alt",
    "cmd": "cmd", "command": "cmd", "super": "cmd", "win": "cmd",
    "up": "up", "down": "down", "left": "left", "right": "right",
    "home": "home", "end": "end",
    "pageup": "page_up", "pgup": "page_up",
    "pagedown": "page_down", "pgdn": "page_down",
    "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4", "f5": "f5",
    "f6": "f6", "f7": "f7", "f8": "f8", "f9": "f9", "f10": "f10",
    "f11": "f11", "f12": "f12",
    "caps": "caps_lock", "capslock": "caps_lock",
    "insert": "insert", "ins": "insert",
}


def _resolve_key(token: str):
    """Turn an agent-supplied key name into a pynput key or single char.

    Special keys like 'enter', 'cmd', 'f5' resolve via the alias table.
    A single character like 'a' or '3' is returned literally — pynput's
    Controller.press accepts strings for printable chars.
    """
    kbd, Key, KeyCode = _keyboard()
    t = (token or "").strip()
    if not t:
        raise ValueError("empty key")
    canonical = _KEY_ALIASES.get(t.lower())
    if canonical:
        return getattr(Key, canonical)
    if len(t) == 1:
        return t  # literal char
    # Try direct Key attr (e.g. 'media_play')
    direct = getattr(Key, t.lower(), None)
    if direct is not None:
        return direct
    raise ValueError(f"unknown key: {token!r}")


@skill(
    "type_text",
    "Type a string into the focused window. Set `interval` to add a small "
    "delay between keypresses (useful for apps that drop fast input).",
    {
        "type": "object",
        "properties": {
            "text": {"type": "string"},
            "interval": {"type": "number", "default": 0.0, "minimum": 0},
        },
        "required": ["text"],
    },
    destructive=True,
)
def type_text(text: str, interval: float = 0.0) -> dict:
    kbd, _, _ = _keyboard()
    if interval <= 0:
        kbd.type(text)
    else:
        for ch in text:
            kbd.type(ch)
            time.sleep(interval)
    return {"ok": True, "chars": len(text)}


@skill(
    "key_press",
    "Press one or more keys. Single string: tap that key. Array: hold "
    "them as a combo (e.g. ['cmd','c']). Special names: enter, esc, "
    "tab, shift, ctrl, alt, cmd, up/down/left/right, f1..f12, etc.",
    {
        "type": "object",
        "properties": {
            "keys": {
                "oneOf": [
                    {"type": "string"},
                    {"type": "array", "items": {"type": "string"}},
                ]
            },
            "hold": {
                "type": "number",
                "description": "Seconds to hold the keys down (0 = tap).",
                "default": 0,
            },
        },
        "required": ["keys"],
    },
    destructive=True,
)
def key_press(keys, hold: float = 0) -> dict:
    kbd, _, _ = _keyboard()
    seq = [keys] if isinstance(keys, str) else list(keys)
    resolved = [_resolve_key(k) for k in seq]

    # Press all modifiers/keys, optionally hold, then release in reverse.
    for k in resolved:
        kbd.press(k)
    try:
        if hold > 0:
            time.sleep(hold)
    finally:
        for k in reversed(resolved):
            try:
                kbd.release(k)
            except Exception:
                pass
    return {"ok": True, "keys": seq}


# ── Notifications ──────────────────────────────────────────────────────────


@skill(
    "notify",
    "Show a desktop notification (toast). Platform-native: macOS uses "
    "Notification Center, Windows uses toast XML, Linux uses notify-send.",
    {
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "message": {"type": "string"},
        },
        "required": ["message"],
    },
)
def notify(title: str = "JarvisCopilot", message: str = "") -> dict:
    title = (title or "JarvisCopilot").replace('"', "'")
    message = (message or "").replace('"', "'")
    sysname = sys.platform

    if sysname == "darwin":
        # osascript display notification.
        script = f'display notification "{message}" with title "{title}"'
        subprocess.run(["osascript", "-e", script], check=False)
        return {"ok": True}

    if sysname == "win32":
        # Inline PowerShell toast — no third-party module needed.
        # If BurntToast is available, use it; otherwise drop a balloon.
        ps = (
            f'$ErrorActionPreference = "SilentlyContinue"; '
            f'[void][Windows.UI.Notifications.ToastNotificationManager, '
            f'Windows.UI.Notifications, ContentType=WindowsRuntime]; '
            f'$T="<toast><visual><binding template=\\"ToastGeneric\\">'
            f'<text>{title}</text><text>{message}</text>'
            f'</binding></visual></toast>"; '
            f'$x = New-Object Windows.Data.Xml.Dom.XmlDocument; '
            f'$x.LoadXml($T); '
            f'$n = New-Object Windows.UI.Notifications.ToastNotification($x); '
            f'[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('
            f'"JarvisCopilot").Show($n)'
        )
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps],
            check=False,
            capture_output=True,
        )
        return {"ok": True}

    # Linux: notify-send if present.
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", title, message], check=False)
        return {"ok": True}
    log.warning("no notification backend; message dropped: %s — %s", title, message)
    return {"ok": False, "error": "no notification backend available"}


# ── Screenshot ─────────────────────────────────────────────────────────────


# Cap a full-display retina capture (~6K × 3.5K) so the WS payload stays
# small. Callers can override with `max_dim`.
_SCREENSHOT_MAX_DIM_DEFAULT = 1600
_SCREENCAPTURE_TIMEOUT_S = 6


@skill(
    "screenshot",
    "Capture the screen and return an image as base64. With `region`={x,y,w,h} "
    "captures just that rectangle. `format` is 'jpeg' (default) or 'png'. "
    "`max_dim` caps the longest side in pixels (default 1600; 0 disables). "
    "Returns {img_b64, format, width, height} and also {png_b64} when format='png' for back-compat.",
    {
        "type": "object",
        "properties": {
            "region": {
                "type": "object",
                "properties": {
                    "x": {"type": "number"},
                    "y": {"type": "number"},
                    "w": {"type": "number"},
                    "h": {"type": "number"},
                },
            },
            "format": {"type": "string", "enum": ["jpeg", "png"]},
            "max_dim": {"type": "number"},
            "quality": {"type": "number"},
        },
    },
)
def screenshot(
    region: dict | None = None,
    format: str = "jpeg",
    max_dim: int | None = None,
    quality: int = 75,
) -> dict:
    fmt = (format or "jpeg").lower()
    if fmt not in ("jpeg", "png"):
        fmt = "jpeg"
    cap = _SCREENSHOT_MAX_DIM_DEFAULT if max_dim is None else int(max_dim)

    t0 = time.monotonic()
    img, src = _grab_screen(region)
    t_grab = time.monotonic() - t0

    try:
        from PIL import Image  # type: ignore
    except Exception:
        Image = None  # type: ignore

    width, height = img.size if img is not None else (0, 0)
    if img is not None and Image is not None and cap > 0:
        long_side = max(width, height)
        if long_side > cap:
            scale = cap / long_side
            new_size = (max(1, int(width * scale)), max(1, int(height * scale)))
            img = img.resize(new_size, Image.LANCZOS)
            width, height = img.size

    t1 = time.monotonic()
    buf = io.BytesIO()
    if img is not None:
        if fmt == "jpeg":
            rgb = img.convert("RGB") if img.mode not in ("RGB", "L") else img
            rgb.save(buf, format="JPEG", quality=int(quality), optimize=True)
        else:
            img.save(buf, format="PNG", optimize=True)
        encoded = buf.getvalue()
    else:
        # No Pillow path returned bytes directly (PNG only).
        encoded = _raw_png_bytes_or_die()
        fmt = "png"
    t_encode = time.monotonic() - t1

    t2 = time.monotonic()
    b64 = base64.b64encode(encoded).decode("ascii")
    t_b64 = time.monotonic() - t2

    log.info(
        "screenshot via=%s fmt=%s size=%dx%d bytes=%d grab=%.2fs encode=%.2fs b64=%.2fs",
        src, fmt, width, height, len(encoded), t_grab, t_encode, t_b64,
    )

    result: dict[str, Any] = {
        "img_b64": b64,
        "format": fmt,
        "width": width,
        "height": height,
    }
    if fmt == "png":
        # Back-compat for callers still reading png_b64.
        result["png_b64"] = b64
    return result


def _grab_screen(region: dict | None):
    """Return (PIL.Image, source_label). On macOS we capture directly via
    the Quartz CGWindowList API — instant, no subprocess, no PNG round
    trip. Falls back to `screencapture -x` if Quartz isn't usable for
    some reason."""
    if sys.platform == "darwin":
        img = _grab_screen_quartz(region)
        if img is not None:
            return img, "quartz"
        return _grab_screen_macos_cli(region), "screencapture"

    # Pillow first on other platforms.
    try:
        from PIL import ImageGrab  # type: ignore

        if region:
            bbox = (
                int(region.get("x", 0)),
                int(region.get("y", 0)),
                int(region.get("x", 0)) + int(region.get("w", 0)),
                int(region.get("y", 0)) + int(region.get("h", 0)),
            )
            return ImageGrab.grab(bbox=bbox), "pillow"
        return ImageGrab.grab(), "pillow"
    except Exception as exc:
        log.debug("ImageGrab unavailable, falling back: %s", exc)

    if sys.platform.startswith("linux"):
        return _grab_screen_linux(region), "linux-cli"
    raise RuntimeError("no screenshot backend on this platform")


def _grab_screen_quartz(region: dict | None):
    """Capture via Quartz CGWindowListCreateImage → PIL Image. Returns
    None if Quartz isn't importable; raises on capture failure (caller
    will fall back)."""
    try:
        from Quartz import (  # type: ignore
            CGWindowListCreateImage,
            CGRectInfinite,
            CGRectMake,
            CGImageGetWidth,
            CGImageGetHeight,
            CGImageGetBytesPerRow,
            CGImageGetDataProvider,
            CGDataProviderCopyData,
            kCGWindowListOptionOnScreenOnly,
            kCGNullWindowID,
            kCGWindowImageDefault,
        )
        from PIL import Image  # type: ignore
    except Exception as exc:
        log.debug("Quartz screenshot unavailable: %s", exc)
        return None

    if region:
        rect = CGRectMake(
            float(region["x"]), float(region["y"]),
            float(region["w"]), float(region["h"]),
        )
    else:
        rect = CGRectInfinite

    img_ref = CGWindowListCreateImage(
        rect,
        kCGWindowListOptionOnScreenOnly,
        kCGNullWindowID,
        kCGWindowImageDefault,
    )
    if img_ref is None:
        # Permission denied (no Screen Recording grant) or off-screen.
        raise RuntimeError(
            "Quartz CGWindowListCreateImage returned NULL — likely missing "
            "Screen Recording permission. Add the venv Python "
            "(`readlink -f ~/Library/Application\\ Support/jc-client/.venv/bin/python`) "
            "to System Settings → Privacy & Security → Screen & System Audio "
            "Recording, then restart the LaunchAgent."
        )

    w = int(CGImageGetWidth(img_ref))
    h = int(CGImageGetHeight(img_ref))
    bpr = int(CGImageGetBytesPerRow(img_ref))
    provider = CGImageGetDataProvider(img_ref)
    data = CGDataProviderCopyData(provider)
    # Quartz captures BGRA (premultiplied alpha). PIL's frombuffer with
    # raw decoder + 'BGRA' converts directly.
    img = Image.frombuffer("RGBA", (w, h), bytes(data), "raw", "BGRA", bpr, 1)
    return img


def _grab_screen_macos_cli(region: dict | None):
    """Legacy `screencapture -x` path — used only if Quartz fails."""
    fd, tmp = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        args = ["screencapture", "-x"]
        if region:
            args += [
                "-R",
                f"{int(region['x'])},{int(region['y'])},{int(region['w'])},{int(region['h'])}",
            ]
        args.append(tmp)
        try:
            proc = subprocess.run(
                args,
                capture_output=True,
                text=True,
                timeout=_SCREENCAPTURE_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"screencapture timed out after {_SCREENCAPTURE_TIMEOUT_S}s — "
                "likely waiting on a TCC prompt the LaunchAgent can't show. "
                "Grant Screen Recording permission to the binary running this "
                "service."
            ) from exc
        if proc.returncode != 0 or not os.path.getsize(tmp):
            stderr = (proc.stderr or "").strip()
            raise RuntimeError(
                f"screencapture exited {proc.returncode}: {stderr or '(no stderr)'}"
            )
        from PIL import Image  # type: ignore

        return Image.open(tmp).copy()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _grab_screen_linux(region: dict | None):
    tool = shutil.which("grim") or shutil.which("scrot") or shutil.which("import")
    if not tool:
        raise RuntimeError("install grim, scrot, or imagemagick for screenshots")
    fd, tmp = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        if tool.endswith("scrot") or tool.endswith("grim"):
            subprocess.run([tool, tmp], check=True, timeout=_SCREENCAPTURE_TIMEOUT_S)
        else:
            subprocess.run(
                [tool, "-window", "root", tmp],
                check=True,
                timeout=_SCREENCAPTURE_TIMEOUT_S,
            )
        from PIL import Image  # type: ignore

        return Image.open(tmp).copy()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _raw_png_bytes_or_die() -> bytes:
    raise RuntimeError("Pillow is required for screenshot encoding")


# ── Mouse / keyboard extras ────────────────────────────────────────────────


@skill(
    "mouse_button",
    "Press or release a mouse button without performing a full click. "
    "Pair `action='press'` with a later `action='release'` to hold during "
    "other actions (e.g. multi-point drags or modifier-clicks).",
    {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["press", "release"]},
            "button": {"type": "string", "default": "left"},
        },
        "required": ["action"],
    },
    destructive=True,
)
def mouse_button(action: str, button: str = "left") -> dict:
    _, m = _mouse()
    btn = _resolve_button(button)
    act = (action or "").strip().lower()
    if act == "press":
        m.press(btn)
    elif act == "release":
        m.release(btn)
    else:
        raise ValueError(f"action must be 'press' or 'release', got {action!r}")
    return {"ok": True, "action": act, "button": button}


@skill(
    "mouse_path",
    "Move the cursor through a sequence of (x, y) points, animating each "
    "segment. `points` is a list like [{x,y}, {x,y}, ...]. Optional "
    "`duration` is total seconds across all segments (default 0.5).",
    {
        "type": "object",
        "properties": {
            "points": {
                "type": "array",
                "minItems": 1,
                "items": {
                    "type": "object",
                    "properties": {
                        "x": {"type": "number"},
                        "y": {"type": "number"},
                    },
                    "required": ["x", "y"],
                },
            },
            "duration": {"type": "number", "default": 0.5, "minimum": 0},
        },
        "required": ["points"],
    },
    destructive=True,
)
def mouse_path(points: list, duration: float = 0.5) -> dict:
    _, m = _mouse()
    if not points:
        raise ValueError("points must contain at least one entry")

    pts = [(int(p["x"]), int(p["y"])) for p in points]
    segs = len(pts)
    per_seg = (duration / segs) if duration > 0 else 0
    cx, cy = m.position
    for tx, ty in pts:
        if per_seg <= 0:
            m.position = (tx, ty)
        else:
            steps = max(2, int(per_seg * 60))
            for i in range(1, steps + 1):
                frac = i / steps
                m.position = (
                    int(cx + (tx - cx) * frac),
                    int(cy + (ty - cy) * frac),
                )
                time.sleep(per_seg / steps)
        cx, cy = tx, ty
    return {"ok": True, "points": len(pts), "end": {"x": cx, "y": cy}}


@skill(
    "key_hold",
    "Press one or more keys WITHOUT releasing them. Pair with `key_release` "
    "to free them later. Useful for holding modifiers while issuing other "
    "skill calls (e.g. hold 'shift' then mouse_click for shift-click).",
    {
        "type": "object",
        "properties": {
            "keys": {
                "oneOf": [
                    {"type": "string"},
                    {"type": "array", "items": {"type": "string"}},
                ]
            },
        },
        "required": ["keys"],
    },
    destructive=True,
)
def key_hold(keys) -> dict:
    kbd, _, _ = _keyboard()
    seq = [keys] if isinstance(keys, str) else list(keys)
    for tok in seq:
        kbd.press(_resolve_key(tok))
    return {"ok": True, "keys": seq}


@skill(
    "key_release",
    "Release keys previously held with `key_hold` (or any keys stuck down). "
    "If `keys` is omitted, releases the common modifier set "
    "(shift, ctrl, alt, cmd) — a 'panic release' for cleaning up after "
    "an interrupted key_hold.",
    {
        "type": "object",
        "properties": {
            "keys": {
                "oneOf": [
                    {"type": "string"},
                    {"type": "array", "items": {"type": "string"}},
                ]
            },
        },
    },
    destructive=True,
)
def key_release(keys=None) -> dict:
    kbd, _, _ = _keyboard()
    if keys is None:
        seq = ["shift", "ctrl", "alt", "cmd"]
    else:
        seq = [keys] if isinstance(keys, str) else list(keys)
    released = []
    for tok in reversed(seq):
        try:
            kbd.release(_resolve_key(tok))
            released.append(tok)
        except Exception:
            pass
    return {"ok": True, "released": list(reversed(released))}


# ── Screen extras ─────────────────────────────────────────────────────────


@skill(
    "screen_info",
    "Return information about attached displays. Yields {displays: "
    "[{index, width, height, x, y, scale, primary}], primary_index}. "
    "Falls back to a single virtual-display entry when only Pillow is available.",
    {"type": "object"},
)
def screen_info() -> dict:
    if sys.platform == "darwin":
        info = _screen_info_macos()
        if info:
            return info

    # Generic fallback via Pillow (combined virtual screen).
    try:
        from PIL import ImageGrab  # type: ignore

        img = ImageGrab.grab()
        return {
            "displays": [
                {
                    "index": 0,
                    "width": img.size[0],
                    "height": img.size[1],
                    "x": 0,
                    "y": 0,
                    "scale": 1.0,
                    "primary": True,
                }
            ],
            "primary_index": 0,
        }
    except Exception as exc:
        raise RuntimeError(f"no display backend available: {exc}") from exc


def _screen_info_macos() -> dict | None:
    """Return per-display info on macOS via system_profiler. Returns None
    if parsing fails so the caller can fall back."""
    try:
        out = subprocess.run(
            ["system_profiler", "SPDisplaysDataType", "-json"],
            capture_output=True,
            text=True,
            timeout=8,
            check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    try:
        import json as _json

        data = _json.loads(out)
    except Exception:
        return None

    displays: list[dict] = []
    idx = 0
    for gpu in data.get("SPDisplaysDataType", []):
        for d in gpu.get("spdisplays_ndrvs", []) or []:
            res = d.get("_spdisplays_resolution") or d.get("spdisplays_resolution") or ""
            # res looks like "3024 x 1964 @ 120.00Hz" or "1512 x 982"
            w = h = 0
            m = re.match(r"\s*(\d+)\s*[xX×]\s*(\d+)", res or "")
            if m:
                w, h = int(m.group(1)), int(m.group(2))
            pixel_res = d.get("_spdisplays_pixels") or ""
            pw = ph = 0
            pm = re.match(r"\s*(\d+)\s*[xX×]\s*(\d+)", pixel_res or "")
            if pm:
                pw, ph = int(pm.group(1)), int(pm.group(2))
            scale = (pw / w) if (pw and w) else 1.0
            primary = bool(d.get("spdisplays_main") == "spdisplays_yes")
            displays.append(
                {
                    "index": idx,
                    "width": w or pw,
                    "height": h or ph,
                    "x": 0,
                    "y": 0,
                    "scale": round(scale, 2),
                    "primary": primary,
                }
            )
            idx += 1
    if not displays:
        return None
    primary_idx = next((d["index"] for d in displays if d["primary"]), 0)
    return {"displays": displays, "primary_index": primary_idx}


@skill(
    "color_at",
    "Return the RGBA color at a screen pixel as {r, g, b, a, hex}. "
    "Uses a 1x1 grab so it's cheap to poll.",
    {
        "type": "object",
        "properties": {
            "x": {"type": "number"},
            "y": {"type": "number"},
        },
        "required": ["x", "y"],
    },
)
def color_at(x: float, y: float) -> dict:
    try:
        from PIL import ImageGrab  # type: ignore
    except Exception as exc:
        raise RuntimeError("color_at needs Pillow") from exc

    ix, iy = int(x), int(y)
    img = ImageGrab.grab(bbox=(ix, iy, ix + 1, iy + 1))
    px = img.convert("RGBA").getpixel((0, 0))
    r, g, b, a = px
    return {
        "r": int(r),
        "g": int(g),
        "b": int(b),
        "a": int(a),
        "hex": f"#{int(r):02x}{int(g):02x}{int(b):02x}",
    }


@skill(
    "screen_highlight",
    "Flash a colored rectangular overlay at (x, y, w, h) for `duration` "
    "seconds (default 1.0). `color` is any Tk color name or '#rrggbb'. "
    "Useful for showing the agent where it's about to click before acting.",
    {
        "type": "object",
        "properties": {
            "x": {"type": "number"},
            "y": {"type": "number"},
            "w": {"type": "number"},
            "h": {"type": "number"},
            "duration": {"type": "number", "default": 1.0, "minimum": 0.05},
            "color": {"type": "string", "default": "red"},
            "thickness": {"type": "number", "default": 4, "minimum": 1},
        },
        "required": ["x", "y", "w", "h"],
    },
)
def screen_highlight(
    x: float,
    y: float,
    w: float,
    h: float,
    duration: float = 1.0,
    color: str = "red",
    thickness: float = 4,
) -> dict:
    # Run Tk in a fresh subprocess so it owns its main thread (required
    # on macOS) and can't crash the service if the windowing backend is
    # missing. Fire-and-forget: we don't block the caller on the flash.
    script = _HIGHLIGHT_SCRIPT
    args = [
        sys.executable, "-c", script,
        str(int(x)), str(int(y)), str(int(w)), str(int(h)),
        str(float(duration)), str(color), str(int(thickness)),
    ]
    try:
        subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception as exc:
        return {"ok": False, "error": f"failed to spawn overlay: {exc}"}
    return {"ok": True}


_HIGHLIGHT_SCRIPT = (
    "import sys\n"
    "import tkinter as tk\n"
    "x, y, w, h = (int(a) for a in sys.argv[1:5])\n"
    "duration = float(sys.argv[5])\n"
    "color = sys.argv[6]\n"
    "thickness = int(sys.argv[7])\n"
    "root = tk.Tk()\n"
    "root.overrideredirect(True)\n"
    "root.attributes('-topmost', True)\n"
    "try:\n"
    "    root.attributes('-alpha', 0.0)\n"
    "    root.attributes('-alpha', 1.0)\n"
    "except tk.TclError:\n"
    "    pass\n"
    "chroma = '#fefffe'\n"
    "try:\n"
    "    root.wm_attributes('-transparentcolor', chroma)\n"
    "except tk.TclError:\n"
    "    pass\n"
    "root.geometry(f'{w}x{h}+{x}+{y}')\n"
    "root.configure(bg=chroma)\n"
    "canvas = tk.Canvas(root, width=w, height=h, bg=chroma, highlightthickness=0)\n"
    "canvas.pack(fill='both', expand=True)\n"
    "canvas.create_rectangle(\n"
    "    thickness // 2, thickness // 2,\n"
    "    max(thickness, w - thickness // 2),\n"
    "    max(thickness, h - thickness // 2),\n"
    "    outline=color, width=thickness,\n"
    ")\n"
    "root.after(int(duration * 1000), root.destroy)\n"
    "root.mainloop()\n"
)


@skill(
    "wait_for_image",
    "Poll the screen until an image template appears, or until `timeout_ms` "
    "elapses. Template is a PNG either as `path` or base64 in `image_b64`. "
    "Returns {found, x, y, score, elapsed_ms} — (x, y) is the top-left of "
    "the best match. `confidence` (0..1) is the minimum normalized score "
    "(default 0.85).",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string"},
            "image_b64": {"type": "string"},
            "timeout_ms": {"type": "number", "default": 5000, "minimum": 0},
            "confidence": {"type": "number", "default": 0.85},
            "poll_ms": {"type": "number", "default": 250, "minimum": 50},
            "region": {
                "type": "object",
                "properties": {
                    "x": {"type": "number"},
                    "y": {"type": "number"},
                    "w": {"type": "number"},
                    "h": {"type": "number"},
                },
            },
        },
    },
)
def wait_for_image(
    path: str | None = None,
    image_b64: str | None = None,
    timeout_ms: float = 5000,
    confidence: float = 0.85,
    poll_ms: float = 250,
    region: dict | None = None,
) -> dict:
    try:
        from PIL import Image, ImageGrab  # type: ignore
    except Exception as exc:
        raise RuntimeError("wait_for_image needs Pillow") from exc
    try:
        import numpy as np  # type: ignore
    except Exception as exc:
        raise RuntimeError(
            "wait_for_image needs numpy (pip install numpy) for matching"
        ) from exc

    if not path and not image_b64:
        raise ValueError("provide `path` or `image_b64`")

    if path:
        template_img = Image.open(path).convert("L")
    else:
        template_img = Image.open(io.BytesIO(base64.b64decode(image_b64))).convert("L")
    tpl = np.asarray(template_img, dtype=np.float32)
    th, tw = tpl.shape
    if th < 4 or tw < 4:
        raise ValueError("template too small (min 4x4)")
    tpl_mean = tpl.mean()
    tpl_centered = tpl - tpl_mean
    tpl_norm = float(np.sqrt((tpl_centered * tpl_centered).sum()))
    if tpl_norm == 0:
        raise ValueError("template has zero variance (solid color)")

    def grab_gray() -> "np.ndarray":
        if region:
            bbox = (
                int(region["x"]),
                int(region["y"]),
                int(region["x"]) + int(region["w"]),
                int(region["y"]) + int(region["h"]),
            )
            img = ImageGrab.grab(bbox=bbox)
        else:
            img = ImageGrab.grab()
        return np.asarray(img.convert("L"), dtype=np.float32)

    start = time.monotonic()
    deadline = start + (timeout_ms / 1000.0)
    best_score = 0.0
    best_xy = (-1, -1)

    while True:
        scene = grab_gray()
        sh, sw = scene.shape
        if sh >= th and sw >= tw:
            score, xy = _best_match(scene, tpl_centered, tpl_norm, th, tw)
            if score > best_score:
                best_score = score
                best_xy = xy
            if score >= confidence:
                elapsed = (time.monotonic() - start) * 1000.0
                ox = int(region["x"]) if region else 0
                oy = int(region["y"]) if region else 0
                return {
                    "found": True,
                    "x": int(xy[0]) + ox,
                    "y": int(xy[1]) + oy,
                    "score": round(score, 4),
                    "elapsed_ms": int(elapsed),
                }
        if time.monotonic() >= deadline:
            elapsed = (time.monotonic() - start) * 1000.0
            ox = int(region["x"]) if region else 0
            oy = int(region["y"]) if region else 0
            return {
                "found": False,
                "x": int(best_xy[0]) + ox if best_xy[0] >= 0 else -1,
                "y": int(best_xy[1]) + oy if best_xy[1] >= 0 else -1,
                "score": round(best_score, 4),
                "elapsed_ms": int(elapsed),
            }
        time.sleep(max(0.01, poll_ms / 1000.0))


def _best_match(scene, tpl_centered, tpl_norm, th, tw):
    """Normalized cross-correlation, vectorized via numpy. Returns
    (best_score in [0, 1], (x, y))."""
    import numpy as np  # type: ignore

    sh, sw = scene.shape
    # Integral image of scene and scene^2 for fast mean/variance of windows.
    ii = np.zeros((sh + 1, sw + 1), dtype=np.float64)
    ii2 = np.zeros((sh + 1, sw + 1), dtype=np.float64)
    ii[1:, 1:] = np.cumsum(np.cumsum(scene, axis=0), axis=1)
    ii2[1:, 1:] = np.cumsum(np.cumsum(scene * scene, axis=0), axis=1)

    area = float(th * tw)
    # window sum = ii[y+th, x+tw] - ii[y, x+tw] - ii[y+th, x] + ii[y, x]
    sums = (
        ii[th:, tw:] - ii[: sh - th + 1, tw:]
        - ii[th:, : sw - tw + 1] + ii[: sh - th + 1, : sw - tw + 1]
    )
    sums2 = (
        ii2[th:, tw:] - ii2[: sh - th + 1, tw:]
        - ii2[th:, : sw - tw + 1] + ii2[: sh - th + 1, : sw - tw + 1]
    )
    means = sums / area
    # variance window = sum2 - mean*sum
    var = sums2 - means * sums
    var[var < 1e-6] = 1e-6
    win_norm = np.sqrt(var)

    # numerator = sum( (scene_window - mean) * tpl_centered )
    #           = sum( scene_window * tpl_centered ) - mean * sum(tpl_centered)
    # tpl_centered has zero mean by construction → second term is 0.
    # Use FFT-based correlation for the dot product.
    from numpy.fft import rfft2, irfft2

    pad_h = sh
    pad_w = sw
    tpl_padded = np.zeros((pad_h, pad_w), dtype=np.float64)
    tpl_padded[:th, :tw] = tpl_centered[::-1, ::-1]
    # Cross-correlation via FFT of flipped template.
    Fs = rfft2(scene, s=(pad_h, pad_w))
    Ft = rfft2(tpl_padded, s=(pad_h, pad_w))
    corr_full = irfft2(Fs * Ft, s=(pad_h, pad_w))
    # The valid top-left positions live at offsets [th-1 .. sh-1] × [tw-1 .. sw-1]
    corr_valid = corr_full[th - 1 : sh, tw - 1 : sw]

    denom = win_norm * tpl_norm
    scores = np.where(denom > 0, corr_valid / denom, 0.0)
    flat_idx = int(np.argmax(scores))
    by, bx = divmod(flat_idx, scores.shape[1])
    best = float(scores[by, bx])
    # Map score from [-1, 1] to [0, 1] so the confidence arg matches automation-mcp.
    best = max(0.0, best)
    return best, (int(bx), int(by))


# ── run_shell (opt-in, NOT registered by default) ──────────────────────────


def _register_run_shell() -> None:
    """Registers the ``run_shell`` skill. Called from skills.load_all
    only when credentials.allow_shell is True. Kept out of module
    import so a plain ``import jc_client.skills.common`` can't expose
    it by mistake."""

    @skill(
        "run_shell",
        "Run a shell command on the client and return stdout/stderr/exit_code. "
        "Requires `allow_shell` to be enabled in the local config. "
        "Use with extreme care — this is full command execution on the host.",
        {
            "type": "object",
            "properties": {
                "cmd": {"type": "string"},
                "timeout": {"type": "number", "default": 30},
                "shell": {"type": "boolean", "default": True},
            },
            "required": ["cmd"],
        },
        destructive=True,
    )
    def run_shell(cmd: str, timeout: float = 30, shell: bool = True) -> dict:
        proc = subprocess.run(
            cmd if shell else cmd.split(),
            shell=shell,
            capture_output=True,
            text=True,
            timeout=max(1.0, min(float(timeout), 600.0)),
        )
        return {
            "exit_code": proc.returncode,
            "stdout": proc.stdout[-4000:],
            "stderr": proc.stderr[-4000:],
            "truncated": (len(proc.stdout) > 4000 or len(proc.stderr) > 4000),
        }
