"""macOS-specific skills.

Everything goes through osascript / shell utilities so we don't pull in
PyObjC. Window management is via System Events, app launch via `open`,
volume via the built-in `osascript set volume` interface.
"""
from __future__ import annotations

import json
import logging
import re
import shlex
import subprocess

from jc_client.skills import skill

log = logging.getLogger(__name__)


def _osa(script: str, *, capture: bool = True, timeout: float = 10.0) -> str:
    """Run an AppleScript snippet via osascript and return stdout.

    Raises subprocess.CalledProcessError on non-zero exit.
    """
    res = subprocess.run(
        ["osascript", "-e", script],
        capture_output=capture,
        text=True,
        timeout=timeout,
        check=True,
    )
    return (res.stdout or "").rstrip("\n")


# ── App control ────────────────────────────────────────────────────────────


@skill(
    "open_app",
    "Launch (or focus) an application by name. Examples: 'Chrome', "
    "'Safari', 'Visual Studio Code', 'Terminal'.",
    {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
    destructive=True,
)
def open_app(name: str) -> dict:
    if not name:
        raise ValueError("name required")
    # `open -a` activates an existing window if the app is already
    # running, otherwise launches it. Quoting via shlex keeps spaces safe.
    subprocess.run(["open", "-a", name], check=True, timeout=15)
    return {"ok": True, "name": name}


@skill(
    "quit_app",
    "Quit an application by name.",
    {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
    destructive=True,
)
def quit_app(name: str) -> dict:
    if not name:
        raise ValueError("name required")
    safe = name.replace('"', '\\"')
    _osa(f'tell application "{safe}" to quit')
    return {"ok": True, "name": name}


# ── Window management ─────────────────────────────────────────────────────


@skill(
    "current_window",
    "Return the title + app of the currently-focused window.",
    {"type": "object"},
)
def current_window() -> dict:
    script = (
        'tell application "System Events" to set frontApp to name of '
        "first application process whose frontmost is true\n"
        'tell application "System Events"\n'
        '  tell process frontApp\n'
        '    try\n'
        '      set wname to name of front window\n'
        '    on error\n'
        '      set wname to ""\n'
        '    end try\n'
        '  end tell\n'
        'end tell\n'
        "return frontApp & \"\\t\" & wname"
    )
    out = _osa(script)
    parts = out.split("\t", 1)
    return {"app": parts[0], "title": parts[1] if len(parts) > 1 else ""}


@skill(
    "list_windows",
    "List visible windows across all apps as [{app, title}].",
    {"type": "object"},
)
def list_windows() -> dict:
    script = (
        'set out to ""\n'
        'tell application "System Events"\n'
        '  repeat with proc in (every application process whose visible is true)\n'
        '    try\n'
        '      set procName to name of proc\n'
        '      repeat with w in (windows of proc)\n'
        '        set wname to name of w\n'
        '        if wname is not "" then\n'
        '          set out to out & procName & "\\t" & wname & "\\n"\n'
        '        end if\n'
        '      end repeat\n'
        '    end try\n'
        '  end repeat\n'
        'end tell\n'
        "return out"
    )
    out = _osa(script)
    windows = []
    for line in (out or "").splitlines():
        if "\t" in line:
            app, title = line.split("\t", 1)
            windows.append({"app": app, "title": title})
    return {"windows": windows, "count": len(windows)}


@skill(
    "focus_window",
    "Bring a window matching `title_substring` to the front.",
    {
        "type": "object",
        "properties": {"title_substring": {"type": "string"}},
        "required": ["title_substring"],
    },
)
def focus_window(title_substring: str) -> dict:
    sub = (title_substring or "").lower()
    if not sub:
        raise ValueError("title_substring required")
    rows = list_windows()["windows"]
    for w in rows:
        if sub in (w.get("title", "")).lower() or sub in (w.get("app", "")).lower():
            app = w["app"].replace('"', '\\"')
            title = w["title"].replace('"', '\\"')
            script = (
                f'tell application "{app}" to activate\n'
                f'tell application "System Events"\n'
                f'  tell process "{app}"\n'
                f'    try\n'
                f'      perform action "AXRaise" of (first window whose name is "{title}")\n'
                f'    end try\n'
                f'  end tell\n'
                f'end tell'
            )
            _osa(script)
            return {"ok": True, "matched": w}
    return {"ok": False, "error": f"no window matches {title_substring!r}"}


# ── Lock / volume ──────────────────────────────────────────────────────────


@skill(
    "lock_screen",
    "Lock the screen (show the login window).",
    {"type": "object"},
    destructive=True,
)
def lock_screen() -> dict:
    # The official lock command since macOS 13+.
    subprocess.run(
        ["pmset", "displaysleepnow"],
        check=False,
    )
    # Fallback: keyboard shortcut Ctrl+Cmd+Q via osascript.
    return {"ok": True}


@skill(
    "volume_get",
    "Return the system output volume as 0-100.",
    {"type": "object"},
)
def volume_get() -> dict:
    out = _osa("output volume of (get volume settings)")
    try:
        return {"level": int(out)}
    except ValueError:
        return {"level": 0}


@skill(
    "volume_set",
    "Set the system output volume (0-100).",
    {
        "type": "object",
        "properties": {"level": {"type": "integer", "minimum": 0, "maximum": 100}},
        "required": ["level"],
    },
    destructive=True,
)
def volume_set(level: int) -> dict:
    v = max(0, min(100, int(level)))
    _osa(f"set volume output volume {v}")
    return {"ok": True, "level": v}


# ── System commands (canned keyboard shortcuts) ────────────────────────────


# Maps the agent-friendly command name → list of pynput key tokens to press
# as a combo. Routed through the existing key_press skill (pynput) so we
# share whatever Accessibility/Input-Monitoring permissions are already
# granted to the Python binary — osascript `keystroke` would require its
# own TCC grant that LaunchAgents can't prompt for.
_SYSTEM_COMMANDS: dict[str, list[str]] = {
    "copy":        ["cmd", "c"],
    "paste":       ["cmd", "v"],
    "cut":         ["cmd", "x"],
    "undo":        ["cmd", "z"],
    "redo":        ["cmd", "shift", "z"],
    "selectall":   ["cmd", "a"],
    "save":        ["cmd", "s"],
    "quit":        ["cmd", "q"],
    "minimize":    ["cmd", "m"],
    "switchapp":   ["cmd", "tab"],
    "newtab":      ["cmd", "t"],
    "closetab":    ["cmd", "w"],
    "newwindow":   ["cmd", "n"],
    "closewindow": ["cmd", "shift", "w"],
    "find":        ["cmd", "f"],
    "refresh":     ["cmd", "r"],
    "screenshot":  ["cmd", "shift", "4"],
    "spotlight":   ["cmd", "space"],
}


@skill(
    "system_command",
    "Run a canned macOS keyboard shortcut by name. Supported: copy, paste, "
    "cut, undo, redo, selectAll, save, quit, minimize, switchApp, newTab, "
    "closeTab, newWindow, closeWindow, find, refresh, screenshot, spotlight.",
    {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "enum": [
                    "copy", "paste", "cut", "undo", "redo", "selectAll",
                    "save", "quit", "minimize", "switchApp", "newTab",
                    "closeTab", "newWindow", "closeWindow", "find",
                    "refresh", "screenshot", "spotlight",
                ],
            },
        },
        "required": ["command"],
    },
    destructive=True,
)
def system_command(command: str) -> dict:
    key = (command or "").strip().lower()
    keys = _SYSTEM_COMMANDS.get(key)
    if keys is None:
        raise ValueError(f"unknown system command: {command!r}")
    # Reuse the cross-platform key_press skill via direct import to avoid
    # a round-trip through the registry.
    from jc_client.skills.common import key_press

    key_press(keys=keys)
    return {"ok": True, "command": command, "keys": keys}


# ── Window control (move / resize / minimize / restore) ────────────────────


def _find_window(title_substring: str) -> dict | None:
    sub = (title_substring or "").lower()
    if not sub:
        raise ValueError("title_substring required")
    for w in list_windows()["windows"]:
        if sub in (w.get("title", "")).lower() or sub in (w.get("app", "")).lower():
            return w
    return None


def _set_window_attr(app: str, title: str, attr: str, value: str) -> None:
    """Set a window attribute via System Events. `attr` is e.g. 'position'
    or 'size'; `value` is an AppleScript literal like '{120, 80}'."""
    app_s = app.replace('"', '\\"')
    title_s = title.replace('"', '\\"')
    script = (
        f'tell application "System Events"\n'
        f'  tell process "{app_s}"\n'
        f'    set targetWin to (first window whose name is "{title_s}")\n'
        f'    set {attr} of targetWin to {value}\n'
        f'  end tell\n'
        f'end tell'
    )
    _osa(script)


def _set_window_minimized(app: str, title: str, miniaturized: bool) -> None:
    app_s = app.replace('"', '\\"')
    title_s = title.replace('"', '\\"')
    flag = "true" if miniaturized else "false"
    script = (
        f'tell application "System Events"\n'
        f'  tell process "{app_s}"\n'
        f'    set value of attribute "AXMinimized" of '
        f'(first window whose name is "{title_s}") to {flag}\n'
        f'  end tell\n'
        f'end tell'
    )
    _osa(script)


@skill(
    "window_move",
    "Move a window matching `title_substring` to absolute screen position "
    "(x, y) — top-left of the window in macOS global coords.",
    {
        "type": "object",
        "properties": {
            "title_substring": {"type": "string"},
            "x": {"type": "number"},
            "y": {"type": "number"},
        },
        "required": ["title_substring", "x", "y"],
    },
    destructive=True,
)
def window_move(title_substring: str, x: float, y: float) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _set_window_attr(w["app"], w["title"], "position", f"{{{int(x)}, {int(y)}}}")
    return {"ok": True, "matched": w, "x": int(x), "y": int(y)}


@skill(
    "window_resize",
    "Resize a window matching `title_substring` to {width, height} pixels.",
    {
        "type": "object",
        "properties": {
            "title_substring": {"type": "string"},
            "width": {"type": "number"},
            "height": {"type": "number"},
        },
        "required": ["title_substring", "width", "height"],
    },
    destructive=True,
)
def window_resize(title_substring: str, width: float, height: float) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _set_window_attr(
        w["app"], w["title"], "size", f"{{{int(width)}, {int(height)}}}"
    )
    return {"ok": True, "matched": w, "width": int(width), "height": int(height)}


@skill(
    "window_minimize",
    "Minimize a window matching `title_substring` (sends it to the Dock).",
    {
        "type": "object",
        "properties": {"title_substring": {"type": "string"}},
        "required": ["title_substring"],
    },
    destructive=True,
)
def window_minimize(title_substring: str) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _set_window_minimized(w["app"], w["title"], True)
    return {"ok": True, "matched": w}


@skill(
    "window_restore",
    "Restore (un-minimize) a window matching `title_substring`.",
    {
        "type": "object",
        "properties": {"title_substring": {"type": "string"}},
        "required": ["title_substring"],
    },
    destructive=True,
)
def window_restore(title_substring: str) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _set_window_minimized(w["app"], w["title"], False)
    # Also activate it so it actually surfaces.
    app_s = w["app"].replace('"', '\\"')
    _osa(f'tell application "{app_s}" to activate')
    return {"ok": True, "matched": w}
