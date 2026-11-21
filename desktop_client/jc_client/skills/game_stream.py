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

import subprocess

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
    except SunshineUnavailable:
        return {"ok": True, "data": {"reachable": False, "paired": [], "apps": []}}
    try:
        apps = c.get_apps()
    except SunshineUnavailable:
        apps = []
    return {"ok": True, "data": {"reachable": True, "paired": paired, "apps": apps}}


def _host_detect(args):
    """Setup probe: is Sunshine running on this PC, and does the login work?
    Returns {running, needs_login} so the setup page can say "Found Sunshine" or
    "running but the login is missing/wrong" instead of a bare reachable flag."""
    c = _client_from(args)
    return {"ok": True, "data": c.probe()}


def _host_ready(args):
    c = _client_from(args)
    return {"ok": True, "data": {"reachable": c.reachable()}}


def _host_pair(args):
    c = _client_from(args)
    try:
        ok = c.submit_pin(str((args or {}).get("pin", "")), (args or {}).get("device"))
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
