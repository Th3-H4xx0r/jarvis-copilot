"""Windows-specific skills — the same names and arguments as skills/mac.py (the server finds a
computer's skills by name, so the PC plugs in where the Mac does).

PowerShell + ctypes (user32/kernel32) + pynput; the pure parts live in _win_helpers.py so they
are tested on any OS. Imported only on win32 (skills/__init__.load_all).
"""
from __future__ import annotations

import ctypes
import json
import ctypes.wintypes as wt
import logging
import os
import re
import subprocess
import threading
import time

from jc_client.skills import skill
from jc_client.skills._win_helpers import (MEDIA_ACTIONS, SPOTIFY_URI, SYSTEM_COMBOS, image_name, media_plan,
                                           volume_script)

log = logging.getLogger(__name__)

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _ps(script: str, *, timeout: float = 15.0, env: dict | None = None) -> str:
    """Run a PowerShell snippet, return stdout stripped of trailing newline. Values from
    outside (a model's app name) go in ``env``, read as $env:NAME — never into the script."""
    res = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True, text=True, timeout=timeout, check=False, creationflags=_NO_WINDOW,
        env={**os.environ, **env} if env else None,
    )
    if res.returncode != 0 and res.stderr.strip():
        raise RuntimeError(res.stderr.strip()[:500])
    return (res.stdout or "").rstrip("\r\n")


def _user32():
    return ctypes.windll.user32  # type: ignore[attr-defined]


def _com_init() -> None:
    """COM on this (executor) thread: comtypes/pythoncom set it up only on the importing thread."""
    try:
        import pythoncom  # type: ignore
        pythoncom.CoInitializeEx(pythoncom.COINIT_MULTITHREADED)
    except Exception:  # noqa: BLE001 — already initialised, or pywin32 missing
        pass


# ── App control ────────────────────────────────────────────────────────────


# What to start for an app's everyday name (live: Start-Process "Calculator" → "file not found"); Mac
# names a plan may still use map to the Windows app that does the same job.
_APP_COMMANDS = {
    "calculator": "calc.exe", "calc": "calc.exe",
    "settings": "ms-settings:", "system settings": "ms-settings:", "windows settings": "ms-settings:",
    "system preferences": "ms-settings:",
    "file explorer": "explorer.exe", "explorer": "explorer.exe", "finder": "explorer.exe",
    "notepad": "notepad.exe", "textedit": "notepad.exe",
    "task manager": "taskmgr.exe", "activity monitor": "taskmgr.exe",
    "paint": "mspaint.exe", "snipping tool": "snippingtool.exe", "control panel": "control.exe",
    "command prompt": "cmd.exe", "powershell": "powershell.exe", "terminal": "wt.exe",
    "windows terminal": "wt.exe", "edge": "msedge.exe", "microsoft edge": "msedge.exe",
    "chrome": "chrome.exe", "google chrome": "chrome.exe", "firefox": "firefox.exe", "brave": "brave.exe",
    "brave browser": "brave.exe", "safari": "msedge.exe",
}
# Start it; failing that, the Start menu's own app list (Store apps have no .exe on PATH).
_OPEN_SCRIPT = (
    "try { Start-Process -FilePath $env:JC_APP -ErrorAction Stop } catch { "
    "$a = Get-StartApps | Where-Object { $_.Name -like ('*' + $env:JC_APP + '*') } | Select-Object -First 1; "
    "if ($a) { Start-Process ('shell:AppsFolder\\' + $a.AppID) } else { throw } }"
)


def open_url_in(url: str, app: str) -> None:
    """Open ``url`` in the browser he named (its everyday name mapped)."""
    _ps("Start-Process -FilePath $env:JC_APP -ArgumentList $env:JC_ARG",
        env={"JC_APP": app_command(app), "JC_ARG": url})


# Everyday names for things the Start menu lists under another name (live 2026-11-19: "Call of Duty: Warzone").
_APP_ALIASES = {"warzone": "call of duty", "cod": "call of duty", "black ops": "call of duty",
                "modern warfare": "call of duty", "wow": "world of warcraft", "ow": "overwatch", "ow2": "overwatch",
                "vs code": "visual studio code", "vscode": "visual studio code", "bnet": "battle.net",
                "battlenet": "battle.net", "blizzard": "battle.net"}
_BATTLENET_EXE = "C:\\Program Files (x86)\\Battle.net\\Battle.net.exe"
_WORD = re.compile(r"[a-z0-9.]+")
_FILLER = {"the", "a", "an", "app", "game", "launch", "open", "start", "on", "my", "pc", "windows"}


def _words(text: str) -> set:
    return {w for w in _WORD.findall(str(text or "").lower().replace("®", "").replace("™", "")) if w not in _FILLER}


def pick_start_app(query: str, apps: list):
    """The Start menu entry a person would pick for ``query``: every word of the entry's name in what he said
    (or the reverse), the closest match first; aliases map nicknames ("warzone" → "Call of Duty")."""
    q = str(query or "").lower()
    for nick, real in _APP_ALIASES.items():
        if re.search(rf"\b{re.escape(nick)}\b", q):
            q = f"{q} {real}"
    want = _words(q)
    if not want:
        return None
    best, best_score = None, 0.0
    for app in apps or []:
        name = _words(app.get("Name"))
        if not name:
            continue
        if name <= want:
            score = 2.0 + len(name) / 10.0          # all of the entry's words: the strongest sign
        elif want <= name:
            score = 1.0 + len(want) / max(len(name), 1)
        else:
            continue
        if score > best_score:
            best, best_score = app, score
    return best


def launch_argv(app: dict, exe_exists=os.path.exists) -> list:
    """How to start a Start menu entry: a Battle.net game through Battle.net's own launch (its Start entry only
    opens the game's page), another link as itself, an app by its AppID."""
    app_id = str(app.get("AppID") or "")
    m = re.match(r"^battlenet://game/(\w+)", app_id, re.I)
    if m and exe_exists(_BATTLENET_EXE):
        return [_BATTLENET_EXE, f'--exec="launch {m.group(1)}"']
    if re.match(r"^[a-z][a-z0-9+.-]*://", app_id, re.I):
        return [app_id]
    return [f"shell:AppsFolder\\{app_id}"]


def app_command(name: str) -> str:
    """The command that starts ``name`` (its everyday name mapped, anything else as given)."""
    return _APP_COMMANDS.get(str(name or "").strip().lower(), str(name or "").strip())


@skill(
    "open_app",
    "Launch an application on the PC by name or path. Common names work via the App Paths "
    "registry: 'chrome', 'edge', 'firefox', 'code', 'notepad', 'explorer', 'cmd', 'powershell', 'spotify'.",
    {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
    destructive=True,
)
def open_app(name: str) -> dict:
    if not name:
        raise ValueError("name required")
    known = str(name).strip().lower() in _APP_COMMANDS or os.path.sep in str(name) or str(name).lower().endswith(".exe")
    if not known:
        app = pick_start_app(name, _start_apps())
        if app is not None:
            argv = launch_argv(app)
            env = {"JC_APP": argv[0], "JC_ARG": argv[1] if len(argv) > 1 else ""}
            _ps("if ($env:JC_ARG) { Start-Process -FilePath $env:JC_APP -ArgumentList $env:JC_ARG } "
                "else { Start-Process -FilePath $env:JC_APP }", env=env)
            return {"ok": True, "name": name, "launched": app.get("Name")}
    _ps(_OPEN_SCRIPT, env={"JC_APP": app_command(name)})
    return {"ok": True, "name": name}


def _start_apps() -> list:
    """The Start menu's app list (name + AppID), as the person sees it."""
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command",
                              "Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress"],
                             capture_output=True, text=True, timeout=20, check=False, creationflags=_NO_WINDOW).stdout
        data = json.loads(out or "[]")
        return data if isinstance(data, list) else [data]
    except Exception:  # noqa: BLE001
        return []


@skill(
    "quit_app",
    "Close an application on the PC by process name (with or without .exe).",
    {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
    destructive=True,
)
def quit_app(name: str) -> dict:
    if not name:
        raise ValueError("name required")
    res = subprocess.run(["taskkill", "/IM", image_name(name), "/F"], capture_output=True, text=True,
                         timeout=15, check=False, creationflags=_NO_WINDOW)
    if res.returncode != 0:
        return {"ok": False, "name": name, "error": (res.stderr or res.stdout or "not running").strip()[:300]}
    return {"ok": True, "name": name}


# ── Windows (the on-screen kind) ───────────────────────────────────────────


def _get_window_title(hwnd: int) -> str:
    u = _user32()
    length = u.GetWindowTextLengthW(hwnd)
    if length == 0:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    u.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def _get_window_process(hwnd: int) -> str:
    pid = wt.DWORD()
    _user32().GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    try:
        import psutil
        return os.path.splitext(psutil.Process(int(pid.value)).name())[0]
    except Exception:  # noqa: BLE001
        return ""


@skill("current_window", "Return the title + process of the PC's focused window.", {"type": "object"})
def current_window() -> dict:
    hwnd = _user32().GetForegroundWindow()
    return {"app": _get_window_process(hwnd), "title": _get_window_title(hwnd), "hwnd": int(hwnd)}


@skill("list_windows", "List the PC's visible top-level windows as [{app, title, hwnd}].", {"type": "object"})
def list_windows() -> dict:
    u = _user32()
    EnumProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    found: list[int] = []

    def _cb(hwnd, _lparam):
        if u.IsWindowVisible(hwnd) and _get_window_title(hwnd):
            found.append(hwnd)
        return True

    u.EnumWindows(EnumProc(_cb), 0)
    windows = [{"app": _get_window_process(h), "title": _get_window_title(h), "hwnd": int(h)}
               for h in found if _get_window_title(h)]
    return {"windows": windows, "count": len(windows)}


def _find_window(title_substring: str):
    sub = (title_substring or "").lower()
    if not sub:
        raise ValueError("title_substring required")
    for w in list_windows()["windows"]:
        if sub in w["title"].lower() or sub in w["app"].lower():
            return w
    return None


@skill(
    "focus_window",
    "Bring a PC window matching `title_substring` to the foreground.",
    {"type": "object", "properties": {"title_substring": {"type": "string"}}, "required": ["title_substring"]},
)
def focus_window(title_substring: str) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _user32().ShowWindow(w["hwnd"], 9)   # SW_RESTORE
    _user32().SetForegroundWindow(w["hwnd"])
    return {"ok": True, "matched": w}


@skill(
    "window_move",
    "Move a PC window matching `title_substring` to absolute screen position (x, y) — its top-left corner.",
    {"type": "object", "properties": {"title_substring": {"type": "string"}, "x": {"type": "number"},
                                      "y": {"type": "number"}}, "required": ["title_substring", "x", "y"]},
    destructive=True,
)
def window_move(title_substring: str, x: float, y: float) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    rect = wt.RECT()
    _user32().GetWindowRect(w["hwnd"], ctypes.byref(rect))
    _user32().MoveWindow(w["hwnd"], int(x), int(y), rect.right - rect.left, rect.bottom - rect.top, True)
    return {"ok": True, "matched": w, "x": int(x), "y": int(y)}


@skill(
    "window_resize",
    "Resize a PC window matching `title_substring` to {width, height} pixels.",
    {"type": "object", "properties": {"title_substring": {"type": "string"}, "width": {"type": "number"},
                                      "height": {"type": "number"}}, "required": ["title_substring", "width", "height"]},
    destructive=True,
)
def window_resize(title_substring: str, width: float, height: float) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    rect = wt.RECT()
    _user32().GetWindowRect(w["hwnd"], ctypes.byref(rect))
    _user32().MoveWindow(w["hwnd"], rect.left, rect.top, int(width), int(height), True)
    return {"ok": True, "matched": w, "width": int(width), "height": int(height)}


@skill(
    "window_minimize",
    "Minimize a PC window matching `title_substring` (sends it to the taskbar).",
    {"type": "object", "properties": {"title_substring": {"type": "string"}}, "required": ["title_substring"]},
    destructive=True,
)
def window_minimize(title_substring: str) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _user32().ShowWindow(w["hwnd"], 6)   # SW_MINIMIZE
    return {"ok": True, "matched": w}


@skill(
    "window_restore",
    "Restore a minimized PC window matching `title_substring`.",
    {"type": "object", "properties": {"title_substring": {"type": "string"}}, "required": ["title_substring"]},
    destructive=True,
)
def window_restore(title_substring: str) -> dict:
    w = _find_window(title_substring)
    if not w:
        return {"ok": False, "error": f"no window matches {title_substring!r}"}
    _user32().ShowWindow(w["hwnd"], 9)   # SW_RESTORE
    return {"ok": True, "matched": w}


# ── Lock / volume ──────────────────────────────────────────────────────────


@skill("lock_screen", "Lock the PC (show the sign-in screen).", {"type": "object"}, destructive=True)
def lock_screen() -> dict:
    _user32().LockWorkStation()
    return {"ok": True}


@skill("volume_get", "Return the PC's master output volume as 0-100.", {"type": "object"})
def volume_get() -> dict:
    try:
        return {"level": int(round(float(_ps(volume_script()).splitlines()[-1])))}
    except Exception:  # noqa: BLE001
        return {"level": 0}


@skill(
    "volume_set",
    "Set the PC's master output volume (0-100).",
    {"type": "object", "properties": {"level": {"type": "integer", "minimum": 0, "maximum": 100}},
     "required": ["level"]},
    destructive=True,
)
def volume_set(level: int) -> dict:
    v = max(0, min(100, int(level)))
    _ps(volume_script(v))
    return {"ok": True, "level": v}


# ── Media, Spotify, speech, shortcuts ──────────────────────────────────────


def _press_vk(vk: int) -> None:
    u = _user32()
    u.keybd_event(vk, 0, 0, 0)
    u.keybd_event(vk, 0, 2, 0)   # KEYEVENTF_KEYUP


def _playing_apps():
    """Apps whose audio session is making sound right now (peak meter), e.g. ["Spotify.exe"];
    None when it can't tell (then play/pause just press the key, as on the Mac)."""
    _com_init()
    try:
        from pycaw.pycaw import AudioUtilities, IAudioMeterInformation
    except Exception:  # noqa: BLE001
        return None
    out = set()
    try:
        sessions = AudioUtilities.GetAllSessions()
        for _ in range(3):
            for s in sessions:
                if s.Process is None:
                    continue
                meter = s._ctl.QueryInterface(IAudioMeterInformation)
                if meter.GetPeakValue() > 0.01:
                    out.add(s.Process.name())
            time.sleep(0.1)
    except Exception:  # noqa: BLE001
        log.debug("audio session scan failed", exc_info=True)
        return None
    return sorted(out)


@skill(
    "media_control",
    "Control music/video playing on the PC — the same as its play/pause, next and previous media "
    "keys, so it reaches whatever app is playing (Spotify, a browser tab). `play` and `pause` do "
    "nothing when it's already in that state. `status` says whether anything is playing.",
    {"type": "object", "properties": {"action": {"type": "string", "enum": list(MEDIA_ACTIONS)}},
     "required": ["action"]},
    destructive=True,
)
def media_control(action: str) -> dict:
    apps = _playing_apps()
    vk, out = media_plan(action, None if apps is None else bool(apps))
    if vk is not None:
        _press_vk(vk)
    if apps and out.get("action") == "status":
        out["apps"] = apps
    return out


@skill(
    "spotify_play",
    "Play a Spotify track, album, playlist, artist or podcast in the PC's Spotify app by its "
    "spotify: URI, opening Spotify if it's closed. Says whether it's playing.",
    {"type": "object", "properties": {"uri": {"type": "string", "description": "e.g. spotify:track:0VjIjW4GlUZAMYd2vXMi3b"}},
     "required": ["uri"]},
)
def spotify_play(uri: str) -> dict:
    uri = (uri or "").strip()
    if not SPOTIFY_URI.fullmatch(uri):
        raise ValueError("uri must be a spotify: URI, e.g. spotify:track:<id>")
    os.startfile(uri)   # type: ignore[attr-defined]  # Spotify's URI handler opens and plays it
    for _ in range(20):
        time.sleep(0.5)
        if any(a.lower() == "spotify.exe" for a in (_playing_apps() or [])):
            return {"ok": True, "uri": uri, "playing": True}
    return {"ok": True, "uri": uri, "playing": False}


@skill(
    "speak_local",
    "Speak text instantly through the PC's own speakers — for a fast local ack ('On it', 'Done') "
    "while a longer response is still on its way. Does not wait for playback to finish.",
    {"type": "object", "properties": {"text": {"type": "string"},
                                      "voice": {"type": "string", "description": "Optional Windows voice name."}},
     "required": ["text"]},
)
def speak_local(text: str, voice: str = "") -> dict:
    text = (text or "").strip()
    if not text:
        raise ValueError("text required")
    text = text[:500]

    def run():
        _com_init()
        try:
            import win32com.client  # type: ignore
            sp = win32com.client.Dispatch("SAPI.SpVoice")
            if voice:
                for v in sp.GetVoices():
                    if voice.lower() in v.GetDescription().lower():
                        sp.Voice = v
                        break
            sp.Speak(text)
        except Exception:  # noqa: BLE001
            log.debug("SAPI speak failed", exc_info=True)

    threading.Thread(target=run, daemon=True, name="speak-local").start()
    return {"ok": True, "spoken": text}


@skill(
    "system_command",
    "Run a canned keyboard shortcut on the PC by name. Supported: copy, paste, cut, undo, redo, "
    "selectAll, save, quit, minimize, switchApp, newTab, closeTab, newWindow, closeWindow, find, "
    "refresh, screenshot, spotlight (Windows search).",
    {"type": "object", "properties": {"command": {"type": "string", "enum": [
        "copy", "paste", "cut", "undo", "redo", "selectAll", "save", "quit", "minimize", "switchApp",
        "newTab", "closeTab", "newWindow", "closeWindow", "find", "refresh", "screenshot", "spotlight"]}},
     "required": ["command"]},
    destructive=True,
)
def system_command(command: str) -> dict:
    combo = SYSTEM_COMBOS.get((command or "").strip().lower())
    if combo is None:
        raise ValueError(f"unknown command {command!r}")
    from jc_client.skills.common import key_press
    key_press(combo)
    return {"ok": True, "command": command, "keys": combo}
