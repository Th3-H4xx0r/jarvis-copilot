"""Linux-specific skills.

Shells out to xdotool / wmctrl / pactl / loginctl / xdg-open / gtk-launch.
On Wayland sessions some of these (xdotool window control) silently
no-op; we report the failure so the agent can fall back.
"""
from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess

from jc_client.skills import skill

log = logging.getLogger(__name__)


def _sh(args: list[str], *, timeout: float = 10.0) -> str:
    res = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    if res.returncode != 0 and not res.stdout:
        err = (res.stderr or "").strip()
        if err:
            raise RuntimeError(err[:500])
    return res.stdout.rstrip("\n")


def _which_or_raise(name: str) -> str:
    p = shutil.which(name)
    if not p:
        raise RuntimeError(f"{name} not installed (apt install {name})")
    return p


# ── App control ────────────────────────────────────────────────────────────


@skill(
    "open_app",
    "Launch an application. Tries `gtk-launch` (desktop-file id) first, "
    "then falls back to running the name as a command on PATH.",
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
    # Try gtk-launch with .desktop-style IDs (firefox, google-chrome, …)
    gl = shutil.which("gtk-launch")
    if gl:
        try:
            subprocess.Popen(
                [gl, name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return {"ok": True, "name": name, "via": "gtk-launch"}
        except Exception:
            pass
    # Fall back to direct exec.
    if shutil.which(name):
        subprocess.Popen(
            [name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return {"ok": True, "name": name, "via": "PATH"}
    # Try xdg-open with the bare name — works for some URL handlers.
    xo = shutil.which("xdg-open")
    if xo:
        try:
            subprocess.Popen(
                [xo, name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return {"ok": True, "name": name, "via": "xdg-open"}
        except Exception:
            pass
    return {"ok": False, "error": f"could not launch {name!r} — not on PATH"}


@skill(
    "quit_app",
    "Kill processes matching `name` (uses pkill).",
    {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
    destructive=True,
)
def quit_app(name: str) -> dict:
    pk = _which_or_raise("pkill")
    subprocess.run([pk, "-f", name], check=False)
    return {"ok": True, "name": name}


# ── Window management (X11 only; Wayland degrades gracefully) ──────────────


def _on_wayland() -> bool:
    return bool(os.environ.get("WAYLAND_DISPLAY"))


@skill(
    "current_window",
    "Return the title + window class of the currently-focused window. "
    "X11 only; returns ok=false on Wayland.",
    {"type": "object"},
)
def current_window() -> dict:
    if _on_wayland():
        return {"ok": False, "error": "current_window not supported on Wayland"}
    xdo = _which_or_raise("xdotool")
    wid = _sh([xdo, "getactivewindow"]).strip()
    if not wid:
        return {"app": "", "title": ""}
    title = _sh([xdo, "getwindowname", wid])
    cls = _sh([xdo, "getactivewindow", "getwindowclassname"]) if False else ""
    # xdotool's getwindowclassname is buggy with arg order; use xprop:
    if shutil.which("xprop"):
        try:
            out = _sh(["xprop", "-id", wid, "WM_CLASS"])
            m = re.search(r'"([^"]+)"', out)
            cls = m.group(1) if m else ""
        except Exception:
            cls = ""
    return {"app": cls, "title": title, "id": wid}


@skill(
    "list_windows",
    "List visible windows as [{app, title, id}]. X11 only.",
    {"type": "object"},
)
def list_windows() -> dict:
    if _on_wayland():
        return {"ok": False, "error": "list_windows not supported on Wayland", "windows": []}
    wm = _which_or_raise("wmctrl")
    out = _sh([wm, "-l", "-x"])
    rows = []
    for line in out.splitlines():
        # wmctrl format: <id> <desktop> <wm-class>.<wm-class>  <host> <title>
        m = re.match(r"^(\S+)\s+\S+\s+(\S+)\s+\S+\s+(.*)$", line)
        if not m:
            continue
        rows.append({"id": m.group(1), "app": m.group(2), "title": m.group(3)})
    return {"windows": rows, "count": len(rows)}


@skill(
    "focus_window",
    "Activate a window whose title or class contains `title_substring`.",
    {
        "type": "object",
        "properties": {"title_substring": {"type": "string"}},
        "required": ["title_substring"],
    },
)
def focus_window(title_substring: str) -> dict:
    if _on_wayland():
        return {"ok": False, "error": "focus_window not supported on Wayland"}
    wm = _which_or_raise("wmctrl")
    sub = (title_substring or "").lower()
    if not sub:
        raise ValueError("title_substring required")
    for w in list_windows().get("windows", []):
        if sub in w["title"].lower() or sub in w["app"].lower():
            _sh([wm, "-i", "-a", w["id"]])
            return {"ok": True, "matched": w}
    return {"ok": False, "error": f"no window matches {title_substring!r}"}


# ── Lock / volume ──────────────────────────────────────────────────────────


@skill(
    "lock_screen",
    "Lock the screen using loginctl / xdg-screensaver / gnome-screensaver.",
    {"type": "object"},
    destructive=True,
)
def lock_screen() -> dict:
    for cmd in (
        ["loginctl", "lock-session"],
        ["xdg-screensaver", "lock"],
        ["gnome-screensaver-command", "--lock"],
    ):
        if shutil.which(cmd[0]):
            subprocess.run(cmd, check=False)
            return {"ok": True, "via": cmd[0]}
    return {"ok": False, "error": "no screen-lock command found"}


@skill(
    "volume_get",
    "Return the system output volume (0-100) using pactl.",
    {"type": "object"},
)
def volume_get() -> dict:
    pc = _which_or_raise("pactl")
    out = _sh([pc, "get-sink-volume", "@DEFAULT_SINK@"])
    m = re.search(r"(\d+)%", out)
    return {"level": int(m.group(1)) if m else 0}


@skill(
    "volume_set",
    "Set the system output volume (0-100) using pactl.",
    {
        "type": "object",
        "properties": {"level": {"type": "integer", "minimum": 0, "maximum": 100}},
        "required": ["level"],
    },
    destructive=True,
)
def volume_set(level: int) -> dict:
    pc = _which_or_raise("pactl")
    v = max(0, min(100, int(level)))
    subprocess.run([pc, "set-sink-volume", "@DEFAULT_SINK@", f"{v}%"], check=True)
    return {"ok": True, "level": v}
