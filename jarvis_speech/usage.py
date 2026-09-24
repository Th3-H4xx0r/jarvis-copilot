"""Seconds of paid engine time per day, so the settings can say what it costs.

Written when a stream closes, never per frame. Two processes (webui, gateway)
may both write; the read-modify-write is atomic per process, so a rare race can
undercount a stream — acceptable for an estimate.
"""
from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import tempfile
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

PRICE_PER_HOUR = 0.12
_KEEP_DAYS = 400
_lock = threading.Lock()


def _path() -> Path:
    try:
        from jarviscopilot_constants import get_hermes_home
        return Path(get_hermes_home()) / "speech_usage.json"
    except Exception:
        return Path(os.getenv("HERMES_HOME") or Path.home() / ".jarviscopilot") / "speech_usage.json"


def _today() -> str:
    return _dt.datetime.now(_dt.timezone.utc).date().isoformat()


def _read() -> dict:
    try:
        data = json.loads(_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def add(surface: str, seconds: float) -> None:
    if not seconds or seconds <= 0:
        return
    try:
        with _lock:
            data = _read()
            row = data.setdefault(_today(), {})
            row[surface] = round(float(row.get(surface) or 0) + float(seconds), 3)
            for day in sorted(data)[:-_KEEP_DAYS]:
                data.pop(day, None)
            path = _path()
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".speech_usage_", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(data, handle)
            os.replace(tmp, path)
    except Exception:
        logger.debug("speech: could not record usage", exc_info=True)


def summary() -> dict:
    data = _read()
    today = _today()
    month = today[:7]
    today_s = sum(float(v or 0) for v in (data.get(today) or {}).values())
    month_s = sum(float(v or 0) for day, row in data.items() if day.startswith(month)
                  and isinstance(row, dict) for v in row.values())
    return {"today_s": round(today_s), "month_s": round(month_s),
            "est_usd": round(month_s / 3600.0 * PRICE_PER_HOUR, 4)}
