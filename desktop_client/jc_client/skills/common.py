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


@skill(
    "screenshot",
    "Capture the screen and return a PNG as base64. With `region`={x,y,w,h} "
    "captures just that rectangle. Returns {png_b64, width, height}.",
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
        },
    },
)
def screenshot(region: dict | None = None) -> dict:
    # Prefer Pillow.ImageGrab when available — works on all three OSes
    # without shelling out. Fall back to native CLI tools.
    try:
        from PIL import ImageGrab  # type: ignore

        if region:
            bbox = (
                int(region.get("x", 0)),
                int(region.get("y", 0)),
                int(region.get("x", 0)) + int(region.get("w", 0)),
                int(region.get("y", 0)) + int(region.get("h", 0)),
            )
            img = ImageGrab.grab(bbox=bbox)
        else:
            img = ImageGrab.grab()
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        b64 = base64.b64encode(buf.getvalue()).decode("ascii")
        return {"png_b64": b64, "width": img.size[0], "height": img.size[1]}
    except Exception as exc:
        log.debug("ImageGrab unavailable, falling back: %s", exc)

    # Native CLI fallbacks.
    fd, tmp = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        if sys.platform == "darwin":
            args = ["screencapture", "-x"]
            if region:
                args += [
                    "-R",
                    f"{int(region['x'])},{int(region['y'])},{int(region['w'])},{int(region['h'])}",
                ]
            args.append(tmp)
            subprocess.run(args, check=True)
        elif sys.platform.startswith("linux"):
            tool = shutil.which("grim") or shutil.which("scrot") or shutil.which("import")
            if not tool:
                raise RuntimeError("install grim, scrot, or imagemagick for screenshots")
            if tool.endswith("scrot"):
                subprocess.run([tool, tmp], check=True)
            elif tool.endswith("grim"):
                subprocess.run([tool, tmp], check=True)
            else:
                subprocess.run([tool, "-window", "root", tmp], check=True)
        else:
            raise RuntimeError("no screenshot backend on this platform")
        data = open(tmp, "rb").read()
        b64 = base64.b64encode(data).decode("ascii")
        # PNG dims w/o Pillow: best effort.
        return {"png_b64": b64}
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


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
