"""Reading and writing one wearable's health space.

The server is the system of record: days, settings, baselines and scores are
documents (so a re-sync of the same day overwrites rather than piles up), while
runs, alerts and measurements are append-only collections.
"""
from __future__ import annotations

import copy
import re
from typing import Any, Optional

from .metrics import Baseline, HealthDay, from_json, parse_instant, to_json, utc_now
from .rules import DEFAULT_RULES

#: What a wearable's health integration does before anyone touches a setting.
DEFAULT_SETTINGS: dict[str, Any] = {
    "enabled": True,
    "model": "",              # empty = whatever the chat model is
    "provider": "",
    "frequency": "every 6 hours",
    "quiet_hours": {"start": "22:00", "end": "08:00"},
    "rules": DEFAULT_RULES,
    "goals": {"steps": 10000, "active_minutes": 30, "sleep_minutes": 480},
    #: Display unit for temperatures in prose; the data is always Celsius.
    "temperature_unit": "celsius",
    #: From the Health tab's profile; heart-rate zones need age.
    "profile": {"sex": "", "age": 0, "height_cm": 0, "weight_kg": 0},
    #: Every wearable that feeds Jarvis Health (see `HealthStore.upsert_device`).
    "devices": [],
    #: Whose sleep, heart, HRV, stress, SpO₂ and temperature count when two
    #: wearables overlap. Empty: the first one that reports them.
    "primary_device": "",
    "timezone": "",
    #: The per-wearable spaces this one absorbed (`jarvis_health.migrate`).
    "migrated_from": [],
    #: Created automatically for every wearable, so not the user's to delete.
    "protected": True,
}

_HEX = re.compile(r"[0-9a-f]+")

# Registry document keys allow only lowercase letters, digits, - and _, so the
# date rides after a dash rather than in a path.
DAY_PREFIX = "day-"
SCORES_PREFIX = "scores-"
BATTERY_PREFIX = "battery-"
WORKOUT_PREFIX = "workout-"
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}$")

#: The one integration every wearable feeds. Protected: it can be paused or
#: cleared, never deleted.
SHARED_SPACE = "jarvis-health"
SHARED_NAME = "Jarvis Health"


def device_key_for(kind: str, device_id: str) -> str:
    """The kind plus the head of the device's own id: `ring-b6ce93c4`."""
    head = ""
    for chunk in _HEX.findall((device_id or "").lower()):
        head = chunk
        break
    return f"{kind}-{(head or 'unknown')[:8]}"


def space_id_for(kind: str, device_id: str) -> str:
    """The space a wearable had to itself before Jarvis Health (migration only)."""
    return f"wearable-{device_key_for(kind, device_id)}"


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
    """The Jarvis Health space, in the vocabulary of health rather than records."""

    def __init__(self, space_id: str = SHARED_SPACE, name: str = "", description: str = "") -> None:
        self.space_id = space_id
        from jarvis_registry.store import shared

        self._registry = shared()
        self._registry.space(
            space_id,
            name=name or (SHARED_NAME if space_id == SHARED_SPACE else space_id),
            description=description or "Health from every linked wearable: days, scores, battery and alerts.",
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
        self._space.put("settings", merged, description="How Jarvis Health runs.")
        return merged

    # ── days ────────────────────────────────────────────────────────────────
    #
    # One record per device per local day. The person's day is a merge of the
    # linked devices' records (`jarvis_health.merge`), never stored twice.

    def put_day(self, day: HealthDay, device: str) -> None:
        body = to_json(day)
        body["synced_at"] = day.synced_at or utc_now()
        body["device"] = device
        self._space.put(f"{DAY_PREFIX}{device}-{day.date}", body, description=f"{device} on {day.date}.")
        # History keeps old days' summaries; this one and its neighbours changed.
        from . import history

        history.forget(self, day.date)

    def day(self, date: str, device: str) -> Optional[HealthDay]:
        raw = self._space.get(f"{DAY_PREFIX}{device}-{date}")
        return from_json(raw) if isinstance(raw, dict) else None

    def device_days(self, date: str) -> dict[str, HealthDay]:
        """Every device's copy of one local day."""
        suffix, out = f"-{date}", {}
        for doc in self._space.documents():
            key = str(doc.get("key", ""))
            if key.startswith(DAY_PREFIX) and key.endswith(suffix):
                device = key[len(DAY_PREFIX):-len(suffix)]
                found = self.day(date, device)
                if found is not None:
                    out[device] = found
        return out

    def dates(self, count: int = 14) -> list[str]:
        """The newest local dates any device has a day for, newest first."""
        keys = [str(d.get("key", "")) for d in self._space.documents()]
        found = {k[-10:] for k in keys if k.startswith(DAY_PREFIX) and _DATE.search(k)}
        return sorted(found, reverse=True)[:count]

    # ── wearables ───────────────────────────────────────────────────────────
    #
    # The roster lives in the settings document so the Integrations page shows
    # it with everything else. Unlinking keeps a device's history; it only
    # stops the sync and keeps its data out of the person's day.

    def roster(self) -> list[dict]:
        return [dict(d) for d in (self.settings().get("devices") or []) if isinstance(d, dict)]

    def linked(self) -> list[dict]:
        return [d for d in self.roster() if d.get("linked", True)]

    def upsert_device(self, entry: dict) -> dict:
        """Add a wearable or refresh it. New ones start linked; the link state is never reset."""
        kind = str(entry.get("kind") or "").strip().lower()
        device_id = str(entry.get("device_id") or "").strip()
        key = entry.get("key") or device_key_for(kind, device_id)
        fresh = {k: v for k, v in {
            "key": key, "kind": kind, "device_id": device_id, "name": entry.get("name"),
            "bridge_device_id": entry.get("bridge_device_id"), "timezone": entry.get("timezone"),
        }.items() if v}
        roster = self.roster()
        current = next((d for d in roster if d.get("key") == key), None)
        if current is None:
            roster.append({**fresh, "linked": True, "added_at": utc_now()})
        else:
            current.update(fresh)
        self.put_settings({"devices": roster})
        return next(d for d in roster if d.get("key") == key)

    def set_linked(self, device: str, linked: bool) -> Optional[dict]:
        roster = self.roster()
        entry = next((d for d in roster if d.get("key") == device), None)
        if entry is None:
            return None
        entry["linked"] = bool(linked)
        self.put_settings({"devices": roster})
        return entry

    def note_synced(self, device: str, at: str) -> None:
        roster = self.roster()
        for entry in roster:
            if entry.get("key") == device:
                entry["last_synced_at"] = at
        self.put_settings({"devices": roster})

    # ── battery ─────────────────────────────────────────────────────────────
    # ── workouts ────────────────────────────────────────────────────────────
    #
    # One record per session, keyed by device and start so a re-sent save
    # replaces its copy instead of doubling it.

    def put_workout(self, workout: dict, device: str) -> dict:
        body = {**workout, "device": device}
        # Registry keys allow lowercase, digits, - and _ only: the start's digits.
        key = f"{WORKOUT_PREFIX}{device}-{''.join(c for c in str(workout['start']) if c.isdigit())}"
        self._space.put(key, body, description=f"{workout.get('sport_name') or 'Workout'} at {workout['start']}.")
        return body

    def workouts(self, start: str, end: str) -> list[dict]:
        """Workouts that began in [start, end), oldest first."""
        begin, finish = parse_instant(start), parse_instant(end)
        out = []
        for doc in self._space.documents():
            key = str(doc.get("key", ""))
            if not key.startswith(WORKOUT_PREFIX):
                continue
            raw = self._space.get(key)
            if isinstance(raw, dict) and raw.get("start") and begin <= parse_instant(raw["start"]) < finish:
                out.append(raw)
        return sorted(out, key=lambda w: w["start"])

    def put_battery(self, date: str, payload: dict) -> None:
        self._space.put(f"{BATTERY_PREFIX}{date}", payload, description=f"Body Battery for {date}.")

    def battery(self, date: str) -> Optional[dict]:
        raw = self._space.get(f"{BATTERY_PREFIX}{date}")
        return raw if isinstance(raw, dict) else None

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
                "ln_hrv_mean": baseline.ln_hrv_mean,
                "ln_hrv_sd": baseline.ln_hrv_sd,
                "hrv_nights": baseline.hrv_nights,
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
            ln_hrv_mean=raw.get("ln_hrv_mean"),
            ln_hrv_sd=raw.get("ln_hrv_sd"),
            hrv_nights=int(raw.get("hrv_nights") or 0),
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
