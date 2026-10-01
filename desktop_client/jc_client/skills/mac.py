"""macOS-specific skills.

Everything goes through osascript / shell utilities so we don't pull in
PyObjC. Window management is via System Events, app launch via `open`,
volume via the built-in `osascript set volume` interface.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import json
import logging
import os
import re
import shlex
import struct
import subprocess
import time

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


def _quartz_windows() -> list[dict] | None:
    """Use the Quartz CGWindowList API to enumerate on-screen windows
    natively (milliseconds). Returns None if Quartz isn't importable so
    the caller can fall back to AppleScript."""
    try:
        from Quartz import (  # type: ignore
            CGWindowListCopyWindowInfo,
            kCGWindowListExcludeDesktopElements,
            kCGWindowListOptionOnScreenOnly,
            kCGNullWindowID,
        )
    except Exception:
        return None
    raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID,
    ) or []
    out: list[dict] = []
    for w in raw:
        # Filter out menubar items, dock, system overlays — layer 0 is
        # normal app windows. Also require an alpha > 0 (visible).
        if int(w.get("kCGWindowLayer", 0)) != 0:
            continue
        if float(w.get("kCGWindowAlpha", 1)) <= 0:
            continue
        title = (w.get("kCGWindowName") or "").strip()
        app = (w.get("kCGWindowOwnerName") or "").strip()
        if not app:
            continue
        # Untitled windows happen (e.g. some browser pickers); skip the
        # noisy ones with no app+title combo of any use.
        if not title and app in ("Window Server", "Dock", "SystemUIServer"):
            continue
        bounds = w.get("kCGWindowBounds") or {}
        out.append({
            "app": app,
            "title": title,
            "pid": int(w.get("kCGWindowOwnerPID", 0)),
            "window_id": int(w.get("kCGWindowNumber", 0)),
            "x": int(bounds.get("X", 0)),
            "y": int(bounds.get("Y", 0)),
            "w": int(bounds.get("Width", 0)),
            "h": int(bounds.get("Height", 0)),
        })
    return out


@skill(
    "current_window",
    "Return the title + app of the currently-focused window.",
    {"type": "object"},
)
def current_window() -> dict:
    # Prefer the Quartz path — instant + no Accessibility prompt.
    # The frontmost app is the first non-zero-layer window with the
    # highest z-order in CGWindowList (which is returned front-to-back).
    qs = _quartz_windows()
    if qs is not None:
        # Frontmost app comes from NSWorkspace; that's the only way to
        # distinguish "frontmost process" from "first window in list".
        try:
            from AppKit import NSWorkspace  # type: ignore

            front = NSWorkspace.sharedWorkspace().frontmostApplication()
            front_pid = int(front.processIdentifier()) if front else 0
            front_name = str(front.localizedName()) if front else ""
        except Exception:
            front_pid, front_name = 0, ""
        if front_pid:
            for w in qs:
                if w["pid"] == front_pid and w["title"]:
                    return {"app": w["app"], "title": w["title"]}
        # Fallback within Quartz: first window of the frontmost app.
        if front_name:
            for w in qs:
                if w["app"] == front_name:
                    return {"app": w["app"], "title": w["title"]}
        if qs:
            return {"app": qs[0]["app"], "title": qs[0]["title"]}

    # Last-resort osascript path.
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
    out = _osa(script, timeout=6.0)
    parts = out.split("\t", 1)
    return {"app": parts[0], "title": parts[1] if len(parts) > 1 else ""}


@skill(
    "list_windows",
    "List visible windows across all apps as [{app, title, pid, "
    "window_id, x, y, w, h}]. Uses the Quartz CGWindowList API — "
    "completes in milliseconds without an Accessibility prompt.",
    {"type": "object"},
)
def list_windows() -> dict:
    qs = _quartz_windows()
    if qs is not None:
        return {"windows": qs, "count": len(qs)}

    # Fallback: AppleScript (slow, but works if Quartz is unavailable).
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
    out = _osa(script, timeout=8.0)
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


# ── Media ──────────────────────────────────────────────────────────────────
#
# The keyboard's ⏯ ⏭ ⏮ keys, posted as system media-key events: they reach
# whichever app owns Now Playing (Music, Spotify, a browser tab) with no
# per-app scripting. MediaRemote would say what's playing, but macOS 15.4+
# refuses it to unentitled processes. The key only toggles, so play/pause first
# ask Core Audio which processes are making sound and skip the key when the
# player is already in the asked-for state.

_MEDIA_ACTIONS = ("play", "pause", "toggle", "next", "previous", "status")
_MEDIA_KEYS = {"next": "media_next", "previous": "media_previous"}
_MEDIA_POLL_S = 0.25
_MEDIA_POLLS = 12  # ~3 s for the player to start or stop its audio
# Players keep the audio device running for several seconds after a pause (and
# take a moment to start), so for this long after pressing play/pause our own
# record of what we asked for beats what Core Audio says.
_MEDIA_TRUST_S = 15.0
_recent: dict = {}  # {"playing": bool, "at": monotonic seconds} of the last press


def _press_media_key(name: str) -> None:
    from jc_client.skills.common import _keyboard

    kbd, Key, _ = _keyboard()
    key = getattr(Key, name)
    kbd.press(key)
    kbd.release(key)


def _fourcc(code: str) -> int:
    return struct.unpack(">I", code.encode())[0]


class _AudioAddress(ctypes.Structure):
    _fields_ = [("selector", ctypes.c_uint32), ("scope", ctypes.c_uint32),
                ("element", ctypes.c_uint32)]


def _audio_property(core_audio, obj: int, selector: str) -> bytes | None:
    address = _AudioAddress(_fourcc(selector), _fourcc("glob"), 0)
    size = ctypes.c_uint32(0)
    if core_audio.AudioObjectGetPropertyDataSize(
            ctypes.c_uint32(obj), ctypes.byref(address), 0, None, ctypes.byref(size)):
        return None
    buf = ctypes.create_string_buffer(size.value)
    if core_audio.AudioObjectGetPropertyData(
            ctypes.c_uint32(obj), ctypes.byref(address), 0, None, ctypes.byref(size), buf):
        return None
    return buf.raw[:size.value]


def _audio_output_pids() -> set[int] | None:
    """PIDs Core Audio says are playing sound right now (macOS 14.2+ process
    objects); None when this macOS can't say."""
    try:
        core_audio = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))
        raw = _audio_property(core_audio, 1, "prs#")  # system object → process list
        if raw is None:
            return None
        pids: set[int] = set()
        for obj in struct.unpack(f"<{len(raw) // 4}I", raw):
            running = _audio_property(core_audio, obj, "piro")
            pid = _audio_property(core_audio, obj, "ppid")
            if running and pid and struct.unpack("<I", running)[0]:
                pids.add(struct.unpack("<i", pid)[0])
        return pids
    except Exception:  # noqa: BLE001 — no CoreAudio means "unknown", not a failed skill
        log.debug("core audio process list unavailable", exc_info=True)
        return None


def _child_pids() -> set[int]:
    """This client's own children (`say`, clips it plays)."""
    res = subprocess.run(["pgrep", "-P", str(os.getpid())],
                         capture_output=True, text=True, check=False)
    return {int(p) for p in res.stdout.split() if p.isdigit()}


def _others_playing() -> set[int] | None:
    """Processes other than Jarvis making sound; None when unknown."""
    pids = _audio_output_pids()
    if pids is None:
        return None
    return pids - {os.getpid()} - _child_pids()


def _process_name(pid: int) -> str:
    res = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                         capture_output=True, text=True, check=False)
    return os.path.basename(res.stdout.strip()) or str(pid)


def _wait_playing(want: bool) -> bool | None:
    state = None
    for _ in range(_MEDIA_POLLS):
        time.sleep(_MEDIA_POLL_S)
        others = _others_playing()
        state = None if others is None else bool(others)
        if state is None or state == want:
            return state
    return state


@skill(
    "media_control",
    "Control music/video playing on this Mac — the same as its play/pause, "
    "next and previous media keys, so it reaches whatever app is playing "
    "(Music, Spotify, a browser tab). `play` and `pause` do nothing when it's "
    "already in that state. `status` says whether anything is playing.",
    {
        "type": "object",
        "properties": {"action": {"type": "string", "enum": list(_MEDIA_ACTIONS)}},
        "required": ["action"],
    },
    destructive=True,
)
def media_control(action: str) -> dict:
    act = (action or "").strip().lower()
    if act not in _MEDIA_ACTIONS:
        raise ValueError(f"action must be one of {', '.join(_MEDIA_ACTIONS)}")
    others = _others_playing()
    playing = None if others is None else bool(others)
    if _recent and time.monotonic() - _recent["at"] < _MEDIA_TRUST_S:
        playing = _recent["playing"]
    if act == "status":
        out = {"ok": True, "action": act}
        if others is None:
            out["note"] = "this macOS can't say what is playing"
        else:
            out["playing"] = playing
            out["apps"] = sorted({_process_name(pid) for pid in others})
        return out
    if act in _MEDIA_KEYS:
        _press_media_key(_MEDIA_KEYS[act])
        return {"ok": True, "action": act, "changed": True}
    if act == "pause" and playing is False:
        return {"ok": True, "action": act, "changed": False, "playing": False,
                "note": "nothing is playing"}
    if act == "play" and playing:
        return {"ok": True, "action": act, "changed": False, "playing": True,
                "note": "already playing"}
    _press_media_key("media_play_pause")
    out = {"ok": True, "action": act, "changed": True}
    if playing is None:
        out["note"] = "pressed play/pause; this macOS can't confirm what is playing"
        return out
    want = not playing if act == "toggle" else act == "play"
    _recent.update(playing=want, at=time.monotonic())
    after = _wait_playing(want)
    out["playing"] = want
    if after is not None and after != want:
        out["confirmed"] = False
        out["note"] = ("key sent; the player is still holding the audio device, which "
                       "some do for a few seconds after pausing"
                       if want is False else
                       "key sent; nothing is making sound yet — the player may still be starting")
    return out


# ── Local ack TTS (plan 4.4-mac) ────────────────────────────────────────────
#
# So the server can trigger an instant local "On it" / "Done" ack on the Mac
# instead of round-tripping audio synthesis + a tunnel hop before anything is
# heard. Fire-and-forget: the skill must return immediately, not block for
# however long the utterance takes to play.

_SPEAK_LOCAL_MAX_CHARS = 500  # plan 4.4-mac: an ack, not a monologue


def _speak_via_nsspeech(text: str, voice: str) -> bool:
    """Best-effort NSSpeechSynthesizer path (pyobjc) — lower latency than
    spawning `say` since it skips a process fork. Returns False (no pyobjc,
    or the call failed) so the caller falls back to `say`, which is always
    present on macOS."""
    try:
        from AppKit import NSSpeechSynthesizer  # type: ignore
    except Exception:
        return False
    try:
        synth = NSSpeechSynthesizer.alloc().initWithVoice_(voice or None)
        if synth is None:
            return False
        synth.startSpeakingString_(text)
        return True
    except Exception:
        log.debug("NSSpeechSynthesizer path failed; falling back to `say`", exc_info=True)
        return False


@skill(
    "speak_local",
    "Speak text instantly through the Mac's own speakers — for a fast local "
    "ack ('On it', 'Done') while a longer response is still on its way over "
    "the network. Does not wait for playback to finish.",
    {
        "type": "object",
        "properties": {
            "text": {"type": "string"},
            "voice": {
                "type": "string",
                "description": "Optional macOS voice name (e.g. 'Samantha'). "
                                "Defaults to the system voice.",
            },
        },
        "required": ["text"],
    },
)
def speak_local(text: str, voice: str = "") -> dict:
    text = (text or "").strip()
    if not text:
        raise ValueError("text required")
    if len(text) > _SPEAK_LOCAL_MAX_CHARS:
        text = text[:_SPEAK_LOCAL_MAX_CHARS]
    voice = (voice or "").strip()

    if _speak_via_nsspeech(text, voice):
        return {"ok": True, "engine": "nsspeech"}

    cmd = ["say"]
    if voice:
        cmd += ["-v", voice]
    cmd.append(text)
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True, "engine": "say"}


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
