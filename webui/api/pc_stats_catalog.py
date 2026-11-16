"""PC Stats: what the PC can report, the widget kinds, and the dashboard model (validation and
the dashboards a new install starts with). Shared by the routes, the store and Jarvis's tools;
the Windows, web and iPhone renderers read it from GET /api/pc-stats/catalog.
"""
from __future__ import annotations

import re
from typing import Optional

GRID_COLUMNS = 12
MAX_WIDGETS = 64
WIDGET_KINDS = ("hero", "number", "chart", "bars", "ring", "sparkline", "text", "session", "moments")
CHARTS = ("area", "line", "none")
STYLE_KEYS = {"chart", "color", "warn", "crit", "window", "decimals", "meta", "label", "unit"}
_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
_DYNAMIC = re.compile(r"^(fan|temp)\.[a-z0-9_]{1,40}$")


def _r(label: str, unit: str, group: str, estimated: bool = False) -> dict:
    return {"label": label, "unit": unit, "group": group, "estimated": estimated}


READINGS: dict[str, dict] = {
    "cpu.load": _r("CPU load", "%", "cpu"),
    "cpu.temp": _r("CPU temperature", "°C", "cpu"),
    "cpu.clock": _r("CPU clock", "MHz", "cpu"),
    "cpu.power": _r("CPU power", "W", "cpu"),
    "gpu.load": _r("GPU load", "%", "gpu"),
    "gpu.temp": _r("GPU temperature", "°C", "gpu"),
    "gpu.hotspot": _r("GPU memory junction", "°C", "gpu"),
    "gpu.clock": _r("GPU clock", "MHz", "gpu"),
    "gpu.mem_clock": _r("GPU memory clock", "MHz", "gpu"),
    "gpu.power": _r("GPU power", "W", "gpu"),
    "gpu.fan": _r("GPU fan", "rpm", "gpu"),
    "gpu.vram_used": _r("VRAM used", "GB", "gpu"),
    "gpu.vram_total": _r("VRAM total", "GB", "gpu"),
    "fps": _r("Frame rate", "fps", "frames"),
    "fps.low1": _r("1% low", "fps", "frames"),
    "frametime": _r("Frame time", "ms", "frames"),
    "ram.used": _r("RAM used", "GB", "memory"),
    "ram.total": _r("RAM total", "GB", "memory"),
    "ram.commit": _r("Committed memory", "GB", "memory"),
    "disk.used": _r("System drive used", "%", "disk"),
    "disk.read": _r("Disk read", "MB/s", "disk"),
    "disk.write": _r("Disk write", "MB/s", "disk"),
    "net.down": _r("Download", "MB/s", "network"),
    "net.up": _r("Upload", "MB/s", "network"),
    "power.cpu": _r("CPU power (model)", "W", "power"),
    "power.gpu": _r("GPU power (model)", "W", "power"),
    "power.ram": _r("RAM power", "W", "power", True),
    "power.disk": _r("Disk power", "W", "power", True),
    "power.net": _r("Network power", "W", "power", True),
    "power.total": _r("PC (est.)", "W", "power", True),
}


def reading_info(key: str) -> Optional[dict]:
    """A fixed reading, or a named fan / temperature the PC reported (fan.<slug>, temp.<slug>)."""
    if key in READINGS:
        return READINGS[key]
    if isinstance(key, str) and _DYNAMIC.match(key):
        kind, _, slug = key.partition(".")
        name = slug.replace("_", " ").title()
        return _r(name, "rpm" if kind == "fan" else "°C", "cooling" if kind == "fan" else "temps")
    return None


def validate_dashboard(d) -> list[str]:
    """Why this dashboard can't be saved (empty list: it can)."""
    errors: list[str] = []
    if not isinstance(d, dict):
        return ["a dashboard must be an object"]
    if not isinstance(d.get("id"), str) or not d["id"].strip():
        errors.append("id must be a non-empty string")
    if not isinstance(d.get("name"), str) or not d["name"].strip():
        errors.append("name must be a non-empty string")
    if d.get("auto") not in (None, "game"):
        errors.append("auto must be null or \"game\"")
    widgets = d.get("widgets")
    if not isinstance(widgets, list):
        return errors + ["widgets must be a list"]
    if len(widgets) > MAX_WIDGETS:
        errors.append(f"at most {MAX_WIDGETS} widgets")
    cells: dict[tuple[int, int], str] = {}
    ids: set[str] = set()
    for i, w in enumerate(widgets):
        where = f"widget {i + 1}"
        if not isinstance(w, dict):
            errors.append(f"{where} must be an object")
            continue
        wid = w.get("id")
        if not isinstance(wid, str) or not wid:
            errors.append(f"{where}: id must be a non-empty string")
        elif wid in ids:
            errors.append(f"{where}: duplicate id {wid!r}")
        else:
            ids.add(wid)
            where = f"widget {wid!r}"
        if w.get("kind") not in WIDGET_KINDS:
            errors.append(f"{where}: kind must be one of {', '.join(WIDGET_KINDS)}")
        try:
            x, y, ww, hh = (int(w.get(k)) for k in ("x", "y", "w", "h"))
        except (TypeError, ValueError):
            errors.append(f"{where}: x, y, w and h must be whole numbers")
            continue
        if x < 0 or y < 0 or ww < 1 or hh < 1 or x + ww > GRID_COLUMNS:
            errors.append(f"{where}: off the {GRID_COLUMNS}-column grid")
        else:
            for cx in range(x, x + ww):
                for cy in range(y, y + hh):
                    if (cx, cy) in cells:
                        errors.append(f"{where}: overlaps {cells[(cx, cy)]!r}")
                        break
                    cells[(cx, cy)] = str(wid)
                else:
                    continue
                break
        readings = w.get("readings", [])
        if not isinstance(readings, list) or any(reading_info(r) is None for r in readings):
            errors.append(f"{where}: unknown reading in {readings!r}")
        style = w.get("style", {})
        if not isinstance(style, dict):
            errors.append(f"{where}: style must be an object")
            continue
        extra = set(style) - STYLE_KEYS
        if extra:
            errors.append(f"{where}: unknown style keys {sorted(extra)}")
        if "chart" in style and style["chart"] not in CHARTS:
            errors.append(f"{where}: chart must be one of {', '.join(CHARTS)}")
        if "color" in style and not (isinstance(style["color"], str) and _COLOR.match(style["color"])):
            errors.append(f"{where}: color must be #RRGGBB")
        if "window" in style:
            try:
                if not 60 <= int(style["window"]) <= 86400:
                    raise ValueError
            except (TypeError, ValueError):
                errors.append(f"{where}: window must be 60-86400 seconds")
        meta = style.get("meta", [])
        if not isinstance(meta, list) or any(reading_info(m) is None for m in meta):
            errors.append(f"{where}: unknown reading in meta {meta!r}")
    return errors


def _w(wid, kind, x, y, w, h, readings, **style) -> dict:
    return {"id": wid, "kind": kind, "x": x, "y": y, "w": w, "h": h, "readings": list(readings), "style": style}


DEFAULTS_VERSION = 2   # bump when the defaults change: dashboards nobody edited are re-seeded


def default_dashboards() -> list[dict]:
    """What a new install starts with (the Apple look, docs/superpowers/specs/2026-11-15-pc-stats-apple-look.md):
    Overview, Gaming (shown on the PC while a game runs) and Power."""
    overview = {"id": "overview", "name": "Overview", "auto": None, "widgets": [
        _w("gpu", "hero", 0, 0, 6, 4, ["gpu.load"], label="GPU", chart="area",
           meta=["gpu.temp", "gpu.clock", "gpu.power", "gpu.vram_used"], warn=85, crit=95),
        _w("cpu", "hero", 6, 0, 6, 4, ["cpu.load"], label="CPU", chart="area",
           meta=["cpu.temp", "cpu.clock", "cpu.power"], warn=90, crit=100),
        _w("frames", "number", 0, 4, 4, 3, ["fps"], label="Frames", chart="area"),
        _w("power", "bars", 4, 4, 4, 3, ["power.gpu", "power.cpu", "power.ram", "power.disk"], label="Power",
           meta=["power.total"]),
        _w("memory", "bars", 8, 4, 4, 3, ["ram.used", "gpu.vram_used", "disk.used"], label="Memory"),
        _w("cooling", "bars", 0, 7, 6, 2, ["gpu.fan"], label="Cooling"),
        _w("network", "chart", 6, 7, 6, 2, ["net.down", "net.up"], label="Network", chart="line", window=600),
    ]}
    gaming = {"id": "gaming", "name": "Gaming", "auto": "game", "widgets": [
        _w("fps", "hero", 0, 0, 8, 4, ["fps"], label="Frame rate", chart="area", meta=["fps.low1", "frametime"]),
        _w("gpuload", "ring", 8, 0, 4, 2, ["gpu.load"], label="GPU"),
        _w("cpuload", "ring", 8, 2, 4, 2, ["cpu.load"], label="CPU"),
        _w("gputemp", "number", 0, 4, 3, 3, ["gpu.temp"], label="GPU temperature", warn=85, crit=95),
        _w("cputemp", "number", 3, 4, 3, 3, ["cpu.temp"], label="CPU temperature", warn=90, crit=100),
        _w("watts", "number", 6, 4, 3, 3, ["power.total"], label="Power"),
        _w("frametime", "number", 9, 4, 3, 3, ["frametime"], label="Frame time", chart="line"),
    ]}
    power = {"id": "power", "name": "Power", "auto": None, "widgets": [
        _w("total", "hero", 0, 0, 6, 4, ["power.total"], label="Power", chart="area"),
        _w("split", "bars", 6, 0, 6, 4, ["power.gpu", "power.cpu", "power.ram", "power.disk", "power.net"],
           label="By part"),
        _w("history", "chart", 0, 4, 12, 4, ["power.total", "power.gpu", "power.cpu"], label="Last hour",
           chart="line", window=3600),
    ]}
    return [overview, gaming, power]
