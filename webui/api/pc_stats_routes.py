"""PC Stats HTTP API, mounted at /api/pc-stats (api/mounts.py); 409 while the pc-stats Power
integration is off (jarvis_power.gate, before this runs).

The PC posts samples (1 Hz while someone watches live, else 10-second averages); the phone,
web and Windows dashboards read live values, history, sessions, moments and energy here, and
read/write the shared dashboards (revision-checked).
"""
from __future__ import annotations

import threading
import time

from api import pc_stats_games
from api.pc_stats_catalog import GRID_COLUMNS, READINGS, WIDGET_KINDS
from api.pc_stats_store import Conflict, store

WATCH_WINDOW = 15.0    # a live viewer keeps the PC sending every second for this long
ONLINE_WINDOW = 30.0   # a sample newer than this means the PC is up

_watched: dict[str, float] = {}
_watched_lock = threading.Lock()
_clock = time.time


def _settings() -> dict:
    try:
        from jarvis_power import discovery
        return discovery.get("pc-stats").read_settings()
    except Exception:
        return {}


def _device(req, body: dict) -> str:
    q = req.query.get("device_id", [""])[0] if req.method == "GET" else ""
    did = str(body.get("device_id") or q or "")
    if did:
        return did
    devices = store().devices()
    return devices[0]["device_id"] if devices else ""


def _name(device_id: str) -> str:
    try:
        from api import device_bridge
        return device_bridge.device_name(device_id) or ""
    except Exception:
        return ""


def _f(req, key: str, default: float) -> float:
    try:
        return float(req.query.get(key, [default])[0])
    except (TypeError, ValueError):
        return default


def _live(device_id: str) -> dict:
    latest = store().latest(device_id) if device_id else None
    at = latest["t"] if latest else None
    return {"device_id": device_id or None, "name": _name(device_id) if device_id else "",
            "online": bool(at and _clock() - at < ONLINE_WINDOW), "at": at,
            "sample": {"r": latest["r"], "game": latest.get("game")} if latest else None,
            "game_name": pc_stats_games.name_of(latest.get("game")) if latest else "",
            "estimated": latest.get("estimated", []) if latest else []}


def _summary(device_id: str) -> dict:
    live = _live(device_id)
    r = (live["sample"] or {}).get("r") or {}
    temps = [v for k, v in r.items() if k in ("cpu.temp", "gpu.temp") or k.startswith("temp.")]
    return {"device_id": live["device_id"], "online": live["online"], "at": live["at"],
            "cpu": r.get("cpu.load"), "gpu": r.get("gpu.load"),
            "cpu_temp": r.get("cpu.temp"), "gpu_temp": r.get("gpu.temp"),
            "hottest": max(temps) if temps else None, "watts": r.get("power.total"),
            "game": (live["sample"] or {}).get("game"), "game_name": live["game_name"]}


def route(req) -> bool:
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    s = store()
    if parts == ["samples"] and req.method == "POST":
        did = str(body.get("device_id") or (req.device or {}).get("id") or "")
        if not did:
            return req.reply(400, {"ok": False, "error": "device_id required"})
        if _settings().get("history", True) is not False:
            s.ingest(did, body.get("samples") or [], body.get("estimated") or [])
            s.add_sessions(did, body.get("sessions") or [])
            s.add_moments(did, body.get("moments") or [])
        else:   # history off: keep only the latest sample for the live views
            samples = body.get("samples") or []
            if samples:
                s.ingest(did, samples[-1:], body.get("estimated") or [])
        with _watched_lock:
            live = _clock() - _watched.get(did, 0) < WATCH_WINDOW
        return req.reply(200, {"ok": True, "live": live})
    if req.method == "GET" and parts == ["live"]:
        did = _device(req, body)
        if did:
            with _watched_lock:
                _watched[did] = _clock()
        return req.reply(200, _live(did))
    if req.method == "GET" and parts == ["summary"]:
        return req.reply(200, _summary(_device(req, body)))
    if req.method == "GET" and parts == ["history"]:
        key = req.query.get("key", [""])[0]
        now = _clock()
        t1 = _f(req, "to", now)
        t0 = _f(req, "from", t1 - 3600)
        return req.reply(200, {"points": s.history(_device(req, body), key, t0, t1, int(_f(req, "points", 300)))})
    if req.method == "GET" and parts == ["sessions"]:
        return req.reply(200, {"sessions": s.sessions(_device(req, body), int(_f(req, "limit", 50)))})
    if req.method == "GET" and parts == ["moments"]:
        now = _clock()
        t1 = _f(req, "to", now)
        return req.reply(200, {"moments": s.moments(_device(req, body), _f(req, "from", t1 - 7 * 86400), t1)})
    if req.method == "GET" and parts == ["energy"]:
        cfg = _settings()
        price = float(cfg.get("price") or 0)
        period = req.query.get("period", ["day"])[0]
        return req.reply(200, {"buckets": s.energy(_device(req, body), period, price), "price": price,
                               "currency": cfg.get("currency") or "USD", "period": period})
    if parts == ["games"] and req.method == "POST":   # the PC: a game's name and icon
        errors = pc_stats_games.put(body.get("exe"), body.get("name"), body.get("icon"))
        return req.reply(400, {"errors": errors}) if errors else req.reply(200, {"ok": True})
    if parts == ["games"] and req.method == "GET":
        return req.reply(200, {"games": pc_stats_games.all_games()})
    if len(parts) == 2 and parts[0] == "games" and req.method == "GET":   # does the server have this icon yet?
        return req.reply(200, {"exe": parts[1], "name": pc_stats_games.name_of(parts[1]), "icon": pc_stats_games.has_icon(parts[1])})
    if req.method == "GET" and parts == ["catalog"]:
        return req.reply(200, {"readings": READINGS, "widget_kinds": list(WIDGET_KINDS), "columns": GRID_COLUMNS})
    if req.method == "GET" and parts == ["settings"]:
        return req.reply(200, {"settings": _settings()})
    if parts == ["dashboards"] and req.method == "GET":
        return req.reply(200, {"dashboards": s.dashboards()})
    if len(parts) == 2 and parts[0] == "dashboards":
        if req.method == "GET":
            d = s.dashboard(parts[1])
            return req.reply(200, {"dashboard": d}) if d else req.reply(404, {"error": "no such dashboard"})
        if req.method == "PUT":
            d = body.get("dashboard") if isinstance(body.get("dashboard"), dict) else None
            if d is None:
                return req.reply(400, {"errors": ["dashboard required"]})
            d = {**d, "id": parts[1]}
            try:
                return req.reply(200, {"dashboard": s.put_dashboard(d, body.get("rev"))})
            except Conflict as e:
                return req.reply(409, {"error": "changed elsewhere", "dashboard": e.current})
            except ValueError as e:
                return req.reply(400, {"errors": e.args[0] if e.args else ["invalid"]})
        if req.method == "DELETE":
            return req.reply(200 if s.delete_dashboard(parts[1]) else 404, {"ok": True})
    return req.reply(404, {"error": "not found"})
