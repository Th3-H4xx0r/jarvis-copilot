"""Reading and writing one wearable's health space.

The server is the system of record: days, settings, baselines and scores are
documents (so a re-sync of the same day overwrites rather than piles up), while
runs, alerts and measurements are append-only collections.
"""
from __future__ import annotations

import copy
import re
from typing import Any, Optional

from .metrics import Baseline, HealthDay, from_json, to_json, utc_now
from .rules import DEFAULT_RULES

#: What a wearable's health integration does before anyone touches a setting.
DEFAULT_SETTINGS: dict[str, Any] = {
    "enabled": True,
    "model": "",              # empty = whatever the chat model is
    "provider": "",
    "frequency": "every 6 hours",
    "quiet_hours": {"start": "22:00", "end": "08:00"},
    "rules": DEFAULT_RULES,
    "goals": {"steps": 10000, "active_minutes": 30},
    #: Display unit for temperatures in prose; the data is always Celsius.
    "temperature_unit": "celsius",
    #: From the wearable's profile screen; heart-rate zones need age.
    "profile": {"sex": "", "age": 0, "height_cm": 0, "weight_kg": 0},
    #: Who this integration is about, filled in when the phone registers it.
    "device_id": "",            # the wearable's own id
    "bridge_device_id": "",     # the phone whose bridge reaches it
    "kind": "",
    "device_name": "",
    "timezone": "",
    #: Created for a wearable, so it is not the user's to delete.
    "protected": True,
}

_HEX = re.compile(r"[0-9a-f]+")

# Registry document keys allow only lowercase letters, digits, - and _, so the
# date rides after a dash rather than in a path.
DAY_PREFIX = "day-"
SCORES_PREFIX = "scores-"


def space_id_for(kind: str, device_id: str) -> str:
    """A short, stable id: the device kind plus the head of its identifier."""
    head = ""
    for chunk in _HEX.findall((device_id or "").lower()):
        head = chunk
        break
    return f"wearable-{kind}-{(head or 'unknown')[:8]}"


def _merge(base: dict, updates: dict) -> dict:
    """Deep-merge, so setting one rule's threshold keeps every other rule."""
    out = copy.deepcopy(base)
    for key, value in (updates or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


class HealthStore:
    """One integration space, in the vocabulary of health rather than records."""

    def __init__(self, space_id: str, name: str = "", description: str = "") -> None:
        self.space_id = space_id
        from jarvis_registry.store import shared

        self._registry = shared()
        self._registry.space(
            space_id,
            name=name or space_id,
            description=description or "Health scores, alerts and stored days for one wearable.",
            icon="heart",
        )
        self._space = self._registry.open(space_id)

    # ── settings ────────────────────────────────────────────────────────────
    def settings(self) -> dict:
        return _merge(DEFAULT_SETTINGS, self._space.get("settings") or {})

    def put_settings(self, updates: dict) -> dict:
        merged = _merge(self.settings(), updates or {})
        merged["protected"] = True
        merged["updated_at"] = utc_now()
        self._space.put("settings", merged, description="How this wearable's health analysis runs.")
        return merged

    # ── days ────────────────────────────────────────────────────────────────
    def put_day(self, day: HealthDay) -> None:
        body = to_json(day)
        body["synced_at"] = day.synced_at or utc_now()
        self._space.put(f"{DAY_PREFIX}{day.date}", body, description=f"Ring data for {day.date}.")

    def day(self, date: str) -> Optional[HealthDay]:
        raw = self._space.get(f"{DAY_PREFIX}{date}")
        return from_json(raw) if isinstance(raw, dict) else None

    def recent_days(self, count: int = 14) -> list[HealthDay]:
        keys = sorted(
            (d["key"] for d in self._space.documents() if str(d.get("key", "")).startswith(DAY_PREFIX)),
            reverse=True,
        )
        days = [self.day(key[len(DAY_PREFIX):]) for key in keys[:count]]
        return [d for d in days if d is not None]

    def newest_day(self) -> Optional[HealthDay]:
        days = self.recent_days(1)
        return days[0] if days else None

    # ── scores and baseline ─────────────────────────────────────────────────
    def put_scores(self, date: str, payload: dict) -> None:
        self._space.put(f"{SCORES_PREFIX}{date}", payload, description=f"Health scores for {date}.")

    def scores(self, date: str) -> Optional[dict]:
        raw = self._space.get(f"{SCORES_PREFIX}{date}")
        return raw if isinstance(raw, dict) else None

    def put_baseline(self, baseline: Baseline) -> None:
        self._space.put(
            "baseline",
            {
                "hrv": baseline.hrv,
                "resting_hr": baseline.resting_hr,
                "bedtime_minute": baseline.bedtime_minute,
                "sleep_minutes": baseline.sleep_minutes,
                "temperature": baseline.temperature,
                "days_used": baseline.days_used,
                "window": baseline.window,
                "updated_at": utc_now(),
            },
            description="Rolling medians of your own days.",
        )

    def baseline(self) -> Baseline:
        raw = self._space.get("baseline") or {}
        return Baseline(
            hrv=raw.get("hrv"),
            resting_hr=raw.get("resting_hr"),
            bedtime_minute=raw.get("bedtime_minute"),
            sleep_minutes=raw.get("sleep_minutes"),
            temperature=raw.get("temperature"),
            days_used=int(raw.get("days_used") or 0),
            window=int(raw.get("window") or 14),
        )

    # ── event streams ───────────────────────────────────────────────────────
    def log_run(self, body: dict) -> int:
        return self._space.append("runs", {**body, "at": body.get("at") or utc_now()}, source="jarvis_health")

    def runs(self, limit: int = 20) -> list[dict]:
        return self._space.records("runs", limit=limit)

    def log_alert(self, body: dict) -> int:
        return self._space.append("alerts", {**body, "at": body.get("at") or utc_now()}, source="jarvis_health")

    def alerts(self, limit: int = 50) -> list[dict]:
        return self._space.records("alerts", limit=limit)

    def fired_today(self, date: str) -> set[str]:
        """Which rules already fired for this local day — one alert per rule per day."""
        out = set()
        for record in self._space.records("alerts", limit=200):
            body = record.get("body") if isinstance(record.get("body"), dict) else record
            if body.get("date") == date and body.get("rule"):
                out.add(body["rule"])
        return out

    # ── held alerts ─────────────────────────────────────────────────────────
    #
    # An alert raised inside quiet hours is not dropped and not pushed at 2am:
    # it waits here and goes out on the first run after the window ends. It has
    # to be a document rather than a collection because the queue is drained.

    def held_alerts(self) -> list[dict]:
        raw = self._space.get("held_alerts") or {}
        held = raw.get("alerts") if isinstance(raw, dict) else None
        return list(held or [])

    def hold_alerts(self, alerts: list[dict]) -> None:
        if not alerts:
            return
        self._space.put(
            "held_alerts",
            {"alerts": self.held_alerts() + list(alerts), "updated_at": utc_now()},
            description="Alerts waiting for quiet hours to end.",
        )

    def take_held_alerts(self) -> list[dict]:
        """Everything waiting, removed from the queue in the same breath."""
        held = self.held_alerts()
        if held:
            self._space.put("held_alerts", {"alerts": [], "updated_at": utc_now()})
        return held

    def log_measurement(self, body: dict) -> int:
        return self._space.append("measurements", body, source="jarvis_health")
