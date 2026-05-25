"""
Location history store for paired mobile devices.

The mobile app pushes periodic GPS fixes to POST /api/devices/mobile/location
(it can't be reliably *pulled* when backgrounded, so the phone reports in).
Each fix is reverse-geocoded to a street address and appended as one JSON
line to ``STATE_DIR/location_history/<device_id>.jsonl``.

The agent answers "where was I…" questions by reading that JSONL directly
(it has shell access) — see the devices SKILL.md. Line shape:

    {"ts": 1716600000.0, "lat": 37.7, "lng": -122.4,
     "accuracy_m": 12.0, "address": "1 Market St, San Francisco, …"}
"""
from __future__ import annotations

import json
import threading
import time
import urllib.parse
import urllib.request

from api.config import STATE_DIR

_LOC_DIR = STATE_DIR / "location_history"
_LOCK = threading.Lock()
# Reverse-geocode cache keyed by a ~11 m coordinate grid, so repeated fixes
# at the same place don't hammer Nominatim (which asks for ≤1 req/sec).
_GEOCODE_CACHE: dict[tuple[float, float], str] = {}
_GEOCODE_CACHE_CAP = 2000


def _file_for(device_id: str):
    _LOC_DIR.mkdir(parents=True, exist_ok=True)
    safe = "".join(c for c in str(device_id) if c.isalnum() or c in "-_")[:64]
    return _LOC_DIR / f"{safe or 'unknown'}.jsonl"


def _reverse_geocode(lat: float, lng: float) -> str:
    key = (round(lat, 4), round(lng, 4))
    with _LOCK:
        if key in _GEOCODE_CACHE:
            return _GEOCODE_CACHE[key]
    address = ""
    try:
        q = urllib.parse.urlencode(
            {"lat": lat, "lon": lng, "format": "jsonv2", "zoom": "18"}
        )
        req = urllib.request.Request(
            f"https://nominatim.openstreetmap.org/reverse?{q}",
            headers={"User-Agent": "JarvisCopilot/1.0 (location-history)"},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        address = str(data.get("display_name") or "")
    except Exception:
        address = ""  # geocoding is best-effort; coords are still stored
    with _LOCK:
        if len(_GEOCODE_CACHE) > _GEOCODE_CACHE_CAP:
            _GEOCODE_CACHE.clear()
        _GEOCODE_CACHE[key] = address
    return address


def record_location(
    device_id: str,
    lat: float,
    lng: float,
    accuracy: float | None = None,
    ts: float | None = None,
    address: str | None = None,
) -> dict:
    """Reverse-geocode (unless [address] supplied) and append one fix."""
    ts = float(ts) if ts is not None else time.time()
    if not address:
        address = _reverse_geocode(lat, lng)
    entry = {
        "ts": ts,
        "lat": lat,
        "lng": lng,
        "accuracy_m": accuracy,
        "address": address,
    }
    line = json.dumps(entry, ensure_ascii=False)
    path = _file_for(device_id)
    with _LOCK:
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    return entry


def history_path(device_id: str) -> str:
    """Absolute path to a device's JSONL history (for docs / the agent)."""
    return str(_file_for(device_id))
