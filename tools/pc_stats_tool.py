"""PC Stats tools — Jarvis reads the gaming PC's stats history and edits its dashboards.

pc_stats_query answers "how hot did the GPU get last night", "what did gaming cost this week";
pc_dashboard lists, reads and edits the dashboards shown on the PC's side monitor, the phone and
the web. Both go to the webui over the host-signed loopback; the server validates every
dashboard write (widget kinds, readings, the 12-column grid, no overlaps) and checks its revision.
"""
from __future__ import annotations

import datetime as dt
import json
import time
import urllib.parse

from tools.chrome_device_tool import _api_request
from tools.registry import registry

COLUMNS = 12


def _out(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, default=str)


def _iso(t) -> str:
    try:
        return dt.datetime.fromtimestamp(float(t)).isoformat(timespec="seconds")
    except (TypeError, ValueError):
        return ""


def pc_stats_query(args=None, **_kw) -> str:
    args = args or {}
    what = str(args.get("what") or "now")
    if what == "now":
        r = _api_request("GET", "/api/pc-stats/live")
        if r.get("_error"):
            return _out({"ok": False, "error": r["_error"]})
        return _out({"ok": True, "online": r.get("online"), "at": _iso(r.get("at")),
                     "readings": (r.get("sample") or {}).get("r", {}), "estimated": r.get("estimated", []),
                     "game": (r.get("sample") or {}).get("game")})
    now = time.time()
    hours = float(args.get("hours") or 24)
    if what == "history":
        key = str(args.get("key") or "")
        if not key:
            return _out({"ok": False, "error": "key is required (e.g. gpu.temp, power.total)"})
        q = urllib.parse.urlencode({"key": key, "from": now - hours * 3600, "to": now, "points": 120})
        r = _api_request("GET", f"/api/pc-stats/history?{q}")
        pts = r.get("points") or []
        if not pts:
            return _out({"ok": True, "key": key, "points": [], "note": "no data in that range"})
        peak = max(pts, key=lambda p: p[3])
        return _out({"ok": True, "key": key, "from": _iso(now - hours * 3600), "to": _iso(now),
                     "avg": round(sum(p[1] for p in pts) / len(pts), 2), "max": peak[3], "max_at": _iso(peak[0]),
                     "min": min(p[2] for p in pts),
                     "points": [[_iso(p[0]), p[1], p[2], p[3]] for p in pts]})
    if what == "sessions":
        r = _api_request("GET", "/api/pc-stats/sessions?limit=20")
        return _out({"ok": True, "sessions": [{**s, "start": _iso(s.get("start")), "end": _iso(s.get("end"))}
                                             for s in r.get("sessions", [])]})
    if what == "moments":
        q = urllib.parse.urlencode({"from": now - hours * 3600, "to": now})
        r = _api_request("GET", f"/api/pc-stats/moments?{q}")
        return _out({"ok": True, "moments": [{**m, "t": _iso(m.get("t"))} for m in r.get("moments", [])]})
    if what == "energy":
        period = str(args.get("period") or "day")
        r = _api_request("GET", f"/api/pc-stats/energy?period={urllib.parse.quote(period)}")
        return _out({"ok": True, "period": period, "currency": r.get("currency"), "price": r.get("price"),
                     "buckets": [{**b, "start": _iso(b.get("start"))} for b in r.get("buckets", [])]})
    return _out({"ok": False, "error": f"unknown what {what!r}"})


def _free_slot(widgets: list, w: int, h: int):
    """The first (x, y), row by row, where a w×h widget fits without overlapping."""
    w = max(1, min(COLUMNS, int(w)))
    taken = {(x, y) for wd in widgets for x in range(int(wd["x"]), int(wd["x"]) + int(wd["w"]))
             for y in range(int(wd["y"]), int(wd["y"]) + int(wd["h"]))}
    for y in range(0, 200):
        for x in range(0, COLUMNS - w + 1):
            if all((cx, cy) not in taken for cx in range(x, x + w) for cy in range(y, y + h)):
                return x, y
    return 0, 200


def _put(d: dict) -> str:
    rev = d.get("rev")
    r = _api_request("PUT", f"/api/pc-stats/dashboards/{urllib.parse.quote(d['id'])}",
                     {"dashboard": {k: v for k, v in d.items() if k != "rev"}, "rev": rev})
    if r.get("dashboard") and not r.get("error"):
        return _out({"ok": True, "dashboard": r["dashboard"]})
    if r.get("errors"):
        return _out({"ok": False, "errors": r["errors"]})
    return _out({"ok": False, "error": r.get("error") or r.get("_error") or "couldn't save"})


def pc_dashboard(args=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "list")
    listing = _api_request("GET", "/api/pc-stats/dashboards")
    if listing.get("_error") or listing.get("error"):
        return _out({"ok": False, "error": listing.get("_error") or listing.get("error")})
    boards = listing.get("dashboards", [])
    if action == "list":
        return _out({"ok": True, "dashboards": [{"id": b["id"], "name": b["name"], "auto": b.get("auto"),
                                                "widgets": len(b.get("widgets", []))} for b in boards]})
    did = str(args.get("dashboard_id") or (args.get("dashboard") or {}).get("id") or "overview")
    board = next((b for b in boards if b["id"] == did), None)
    if action == "get":
        return _out({"ok": True, "dashboard": board}) if board else _out({"ok": False, "error": f"no dashboard {did!r}"})
    if action == "put":
        d = args.get("dashboard")
        if not isinstance(d, dict):
            return _out({"ok": False, "error": "dashboard (object) is required"})
        return _put({**d, "id": did, "rev": board.get("rev") if board else None})
    if board is None:
        return _out({"ok": False, "error": f"no dashboard {did!r}"})
    widgets = [dict(w) for w in board.get("widgets", [])]
    if action == "add_widget":
        w = dict(args.get("widget") or {})
        w.setdefault("id", f"w{int(time.time() * 1000) % 10_000_000}")
        w.setdefault("w", 3)
        w.setdefault("h", 2)
        w.setdefault("readings", [])
        w.setdefault("style", {})
        if "x" not in w or "y" not in w:
            w["x"], w["y"] = _free_slot(widgets, w["w"], w["h"])
        widgets.append(w)
    elif action == "update_widget":
        wid = str(args.get("widget_id") or (args.get("widget") or {}).get("id") or "")
        i = next((i for i, w in enumerate(widgets) if w["id"] == wid), None)
        if i is None:
            return _out({"ok": False, "error": f"no widget {wid!r}"})
        patch = dict(args.get("widget") or {})
        style = {**widgets[i].get("style", {}), **(patch.pop("style", None) or {})}
        widgets[i] = {**widgets[i], **patch, "id": wid, "style": style}
    elif action == "remove_widget":
        wid = str(args.get("widget_id") or "")
        if not any(w["id"] == wid for w in widgets):
            return _out({"ok": False, "error": f"no widget {wid!r}"})
        widgets = [w for w in widgets if w["id"] != wid]
    else:
        return _out({"ok": False, "error": f"unknown action {action!r}"})
    return _put({**board, "widgets": widgets})


_WIDGET = {
    "type": "object",
    "description": ("A widget on the 12-column grid: id, kind (hero, number, chart, bars, ring, sparkline, stats = a grid "
                    "of labelled numbers, text, session, moments), x, y, w, h (grid cells; omit x/y to auto-place), "
                    "readings (e.g. [\"gpu.temp\"]; \"temp.*\" / \"fan.*\" = every temperature / fan), style {chart: area|line|none, color: #RRGGBB, warn, crit, window (s), "
                    "decimals, meta: [readings shown under a hero], label, unit}."),
}

registry.register(
    name="pc_stats_query", toolset="pc_stats", emoji="📈",
    schema={
        "name": "pc_stats_query",
        "description": ("Pranav's gaming PC stats: now (live readings), history of one reading (gpu.temp, cpu.temp, "
                        "fps, power.total, gpu.load, cpu.load, ram.used …) over the last N hours, game sessions, "
                        "marked problem moments, or energy and cost per day/week/month."),
        "parameters": {"type": "object", "properties": {
            "what": {"type": "string", "enum": ["now", "history", "sessions", "moments", "energy"]},
            "key": {"type": "string", "description": "For history: the reading key"},
            "hours": {"type": "number", "description": "For history/moments: how far back (default 24)"},
            "period": {"type": "string", "enum": ["day", "week", "month"]},
        }, "required": ["what"]},
    },
    handler=lambda args, **kw: pc_stats_query(args, **kw),
)

registry.register(
    name="pc_dashboard", toolset="pc_stats", emoji="🧩",
    schema={
        "name": "pc_dashboard",
        "description": ("Read or edit the PC Stats dashboards (shown on the PC's side monitor, the phone and the web). "
                        "Get a dashboard first to see widget ids and positions, then add/update/remove widgets or put "
                        "a whole dashboard. Writes are validated by the server; errors say what to fix."),
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["list", "get", "put", "add_widget", "update_widget", "remove_widget"]},
            "dashboard_id": {"type": "string", "description": "e.g. overview, gaming, power (default overview)"},
            "dashboard": {"type": "object", "description": "For put: {id, name, auto: null|\"game\", widgets: [...]}"},
            "widget": _WIDGET,
            "widget_id": {"type": "string"},
        }, "required": ["action"]},
    },
    handler=lambda args, **kw: pc_dashboard(args, **kw),
)
