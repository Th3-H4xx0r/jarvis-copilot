"""His time zone — where his phone says he is, not where the server sits.

Order: the phone's last context snapshot → the newest time zone a wearable
sync reported → the configured ``timezone`` → America/Chicago. Cached for a
minute; the server itself runs in UTC, which put his evenings on the next day.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)

DEFAULT_ZONE = "America/Chicago"
_TTL = 60.0
_lock = threading.Lock()
_cache: dict = {"at": 0.0, "zone": None}


def reset_cache() -> None:
    with _lock:
        _cache.update(at=0.0, zone=None)


def snapshot_path() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return Path(get_hermes_home()) / "memory" / "context_snapshot.json"


def _snapshot_zone() -> str:
    try:
        return str(json.loads(snapshot_path().read_text(encoding="utf-8")).get("tz") or "")
    except Exception:
        return ""


def _roster_zone() -> str:
    """The time zone the phone sent with its newest wearable sync."""
    try:
        from jarvis_health.store import HealthStore
        rows = HealthStore().roster() or []
    except Exception:
        return ""
    best, best_at = "", ""
    for row in rows:
        zone = str((row or {}).get("timezone") or "")
        at = str((row or {}).get("last_synced_at") or "")
        if zone and at >= best_at:
            best, best_at = zone, at
    return best


def _configured_zone() -> str:
    try:
        from jarviscopilot_time import _resolve_timezone_name
        return _resolve_timezone_name() or ""
    except Exception:
        return ""


def _valid(name: str):
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except Exception:
        return None


def user_zone() -> ZoneInfo:
    now = time.monotonic()
    with _lock:
        if _cache["zone"] is not None and now - _cache["at"] < _TTL:
            return _cache["zone"]
    zone = None
    for source in (_snapshot_zone, _roster_zone, _configured_zone):
        zone = _valid(source())
        if zone is not None:
            break
    zone = zone or ZoneInfo(DEFAULT_ZONE)
    with _lock:
        _cache.update(at=now, zone=zone)
    return zone
