"""Game streaming (Sunshine + Moonlight): jc-client skills + per-device connect drivers.

Host control (status / ready / pair / unpair / stop) runs on the PC via the
Sunshine local API. Client connect runs on the target device: the Mac drives
moonlight-qt's CLI; an Android TV is driven over adb from the PC; iOS has no
local driver, so the server sends a tap-to-connect push.

A Sunshine stream is client-initiated, so "connect" is what actually starts a
stream — it points Moonlight at host+app. When a game is already running
locally the caller sets stream_running_session, and connect streams the Desktop
(the running session) instead of launching a second copy.

NOTE (verify live): the Android Moonlight launch intent (component + extras)
and the moonlight-qt binary name are representative; confirm against the real
apps and adjust.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from jc_client.skills import skill
from jc_client.sunshine import SunshineAuthError, SunshineClient, SunshineUnavailable  # noqa: F401

DESKTOP_APP = "Desktop"


def _run(cmd, timeout=15):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ── per-device connect drivers ───────────────────────────────────────────
def _connect_mac(host, app, *, moonlight="moonlight", run=_run):
    cmd = [moonlight, "stream", host, app]
    try:
        r = run(cmd)
    except FileNotFoundError:
        return {"ok": False, "detail": "Moonlight not found on the Mac — install moonlight-qt."}
    if getattr(r, "returncode", 0) != 0:
        return {"ok": False, "detail": (getattr(r, "stderr", "") or "Moonlight failed").strip()}
    return {"ok": True, "detail": f"streaming {app} to Mac", "cmd": cmd}


def _connect_androidtv(host, app, tv_addr, *, adb="adb", run=_run):
    if not tv_addr:
        return {"ok": False, "detail": "No Android TV address configured."}
    try:
        run([adb, "connect", tv_addr])
        intent = [adb, "-s", tv_addr, "shell", "am", "start",
                  "-n", "com.limelight/.ShortcutTrampoline",
                  "--es", "UUID", host, "--es", "AppName", app]
        r = run(intent)
    except FileNotFoundError:
        return {"ok": False,
                "detail": "adb not found on the PC — install Android platform-tools and enable ADB on the TV."}
    if getattr(r, "returncode", 0) != 0:
        return {"ok": False, "detail": (getattr(r, "stderr", "") or "adb launch failed").strip()}
    return {"ok": True, "detail": f"launched {app} on Android TV", "cmd": intent}


def _connect_ios(host, app):
    # iOS has no local driver; the server sends a tap-to-connect push.
    return {"ok": True, "detail": "tap-to-connect push", "push": True, "host": host, "app": app}


def connect(target, app, stream_running_session=False, *, run=_run):
    """Dispatch to the right client driver. target = {kind, host, tv_addr?}."""
    t = target or {}
    kind = t.get("kind")
    host = t.get("host")
    play = DESKTOP_APP if stream_running_session else app
    if kind == "mac":
        return _connect_mac(host, play, run=run)
    if kind == "androidtv":
        return _connect_androidtv(host, play, t.get("tv_addr"), run=run)
    if kind == "ios":
        return _connect_ios(host, play)
    return {"ok": False, "detail": f"unknown target kind: {kind!r}"}


# ── host control (PC) via the Sunshine API ───────────────────────────────
def _client_from(args):
    # jc-client runs ON the gaming PC, so Sunshine is always at localhost: the server
    # sends only the credentials and host/port default here (never typed by the user).
    s = (args or {}).get("sunshine") or {}
    return SunshineClient(
        s.get("host") or "127.0.0.1", int(s.get("port") or 47990),
        s.get("user", ""), s.get("password", ""),
        scheme=s.get("scheme") or "https")


def _host_status(args):
    c = _client_from(args)
    try:
        paired = c.get_clients()
    except SunshineAuthError:
        # Running, but the login is wrong/missing (HTTP 401/403) — not "offline". The
        # status page must say "needs sign-in", never "host unreachable".
        return {"ok": True, "data": {"reachable": False, "needs_login": True,
                                     "paired": [], "apps": []}}
    except SunshineUnavailable:
        return {"ok": True, "data": {"reachable": False, "needs_login": False,
                                     "paired": [], "apps": []}}
    try:
        apps = c.get_apps()
    except SunshineUnavailable:
        apps = []
    return {"ok": True, "data": {"reachable": True, "needs_login": False,
                                 "paired": paired, "apps": apps}}


_STATE_FILE = "sunshine_state.json"


def _state_file_candidates(log_path=""):
    """Where Sunshine's state file might live. The state file sits in Sunshine's config
    dir next to its log, so when we know the log path we look right beside it; otherwise
    we fall back to the per-OS default config dir."""
    cands = []
    lp = str(log_path or "").strip()
    if lp:
        cands.append(Path(lp).expanduser().parent / _STATE_FILE)
    if os.name == "nt" or sys.platform.startswith("win"):
        cands.append(Path(r"C:\Program Files\Sunshine\config") / _STATE_FILE)
    else:
        cands.append(Path.home() / ".config" / "sunshine" / _STATE_FILE)
        if sys.platform == "darwin":
            cands.append(Path("/opt/homebrew/etc/sunshine") / _STATE_FILE)
        cands.append(Path("/etc/sunshine") / _STATE_FILE)
    return cands


def sunshine_username(log_path=""):
    """The Sunshine web-UI username from sunshine_state.json (found next to the
    configured/default log path). Sunshine writes a flat {"username": ...} there;
    some builds nest it under "root", so we check both. Returns "" when the file is
    missing or unreadable — setup then just leaves the field as the user typed it."""
    for path in _state_file_candidates(log_path):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        name = data.get("username")
        if not name and isinstance(data.get("root"), dict):
            name = data["root"].get("username")
        name = str(name or "").strip()
        if name:
            return name
    return ""


def _host_detect(args):
    """Setup probe: is Sunshine running on this PC, does the login work, and what is the
    configured username? Returns {running, needs_login, username} so the setup page can
    auto-fill the username and say "Found Sunshine" or "running but the login is
    missing/wrong" instead of a bare reachable flag."""
    c = _client_from(args)
    data = c.probe()
    data["username"] = sunshine_username(str((args or {}).get("log_path") or ""))
    return {"ok": True, "data": data}


def _host_ready(args):
    c = _client_from(args)
    return {"ok": True, "data": {"reachable": c.reachable()}}


def _host_pair(args):
    c = _client_from(args)
    try:
        ok = c.submit_pin(str((args or {}).get("pin", "")), (args or {}).get("device"))
    except SunshineAuthError:
        return {"ok": False,
                "detail": "Sunshine rejected the login — check your Sunshine password"}
    except SunshineUnavailable as e:
        return {"ok": False, "detail": f"Sunshine unavailable: {e}"}
    return {"ok": bool(ok), "detail": "paired" if ok else "pairing rejected"}


def _host_unpair(args):
    c = _client_from(args)
    try:
        c.unpair(str((args or {}).get("uuid", "")))
    except SunshineUnavailable as e:
        return {"ok": False, "detail": f"Sunshine unavailable: {e}"}
    return {"ok": True, "detail": "unpaired"}


def _host_stop(args):
    c = _client_from(args)
    try:
        c.close_app()
    except SunshineUnavailable as e:
        return {"ok": False, "detail": f"Sunshine unavailable: {e}"}
    return {"ok": True, "detail": "stopped"}


def _connect_skill(args):
    a = args or {}
    return connect(a.get("target"), a.get("app"), a.get("stream_running_session", False))


# ── registration ─────────────────────────────────────────────────────────
_CONNECT_SCHEMA = {
    "type": "object",
    "properties": {
        "target": {"type": "object"},
        "app": {"type": "string"},
        "stream_running_session": {"type": "boolean"},
    },
}


def register():
    """Connect driver — registered on every device (Mac / PC / handheld)."""
    skill("game_stream_connect",
          "Point this device's Moonlight at the Sunshine host and stream an app.",
          _CONNECT_SCHEMA, destructive=True)(_connect_skill)


def register_host():
    """Sunshine host control — registered on the PC only."""
    skill("game_stream_status", "Report Sunshine reachability, paired devices and apps.",
          {"type": "object"})(_host_status)
    skill("game_stream_detect",
          "Detect Sunshine on this PC for setup: whether it is running and whether the login works.",
          {"type": "object"})(_host_detect)
    skill("game_stream_ready", "Check the Sunshine host is reachable.",
          {"type": "object"})(_host_ready)
    skill("game_stream_pair", "Submit a Moonlight pairing PIN to the Sunshine host.",
          {"type": "object"}, destructive=True)(_host_pair)
    skill("game_stream_unpair", "Unpair a device from the Sunshine host.",
          {"type": "object"}, destructive=True)(_host_unpair)
    skill("game_stream_stop", "Stop the running Sunshine app / session.",
          {"type": "object"}, destructive=True)(_host_stop)
