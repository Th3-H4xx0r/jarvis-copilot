"""Reading and writing one wearable's health space.

The server is the system of record: days, settings, baselines and scores are
documents (so a re-sync of the same day overwrites rather than piles up), while
runs, alerts and measurements are append-only collections.
"""
from __future__ import annotations

import copy
import re
from datetime import timezone
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
# An outdoor workout's route, one document per workout beside it (same suffix):
# `route-ring-b6ce93c4-20260919180000`. The workout itself carries only a
# `route_summary`, so the day and /now stay small.
ROUTE_PREFIX = "route-"
# A registry document holds at most 1 MiB; a stored point is ~50 bytes.
MAX_ROUTE_POINTS = 15_000
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}$")

# Strength training the phone keeps here: templates and custom exercises one
# document each, and every exercise's settings (rest, bar, kind, pinned note)
# in one.
# A scale's readings, one document per device per UTC day: `weight-scale-3c0f01eb-20260919`.
WEIGHT_PREFIX = "weight-"

TEMPLATE_PREFIX = "template-"
EXERCISE_PREFIX = "exercise-"
TRAINING_SETTINGS = "training-settings"
# A prefix plus this fits the registry's 64-character keys.
_TRAINING_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,54}")
#: The key a workout's device is filed under: `ring-b6ce93c4`.
_DEVICE_KEY = re.compile(r"[a-z]+-[a-z0-9]{1,16}")


def _weight_reading(raw: Any) -> dict:
    """One weigh-in as the phone sends it, checked: an id, a zoned instant, kilograms."""
    if not isinstance(raw, dict) or not raw.get("id") or not raw.get("at"):
        raise ValueError("a reading needs an 'id' and an 'at'")
    at = parse_instant(str(raw["at"]))
    if at.tzinfo is None:
        raise ValueError("a reading's 'at' is a UTC instant: 2026-09-19T07:12:00Z")
    kg = raw.get("weight_kg")
    if not isinstance(kg, (int, float)) or not 10 <= kg <= 400:
        raise ValueError("a reading's weight_kg is between 10 and 400")
    out = {"id": str(raw["id"])[:64], "at": at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "weight_kg": round(float(kg), 2)}
    for key in ("bmi", "body_fat", "muscle_mass", "body_water", "bone_mass", "visceral_fat", "bmr"):
        value = raw.get(key)
        if isinstance(value, (int, float)):
            out[key] = round(float(value), 2)
    return out


def _training_id(value: Any) -> str:
    """An id the phone chose, checked before it becomes part of a key."""
    text = str(value or "")
    if not _TRAINING_ID.fullmatch(text):
        raise ValueError(f"not a usable id: {text!r} (lowercase letters, digits, - and _)")
    return text

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
        self._weights_cache = None
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

    @staticmethod
    def _workout_key(start: Any, device: str) -> str:
        # Registry keys allow lowercase, digits, - and _ only: the start's digits.
        return f"{WORKOUT_PREFIX}{device}-{''.join(c for c in str(start) if c.isdigit())}"

    def put_workout(self, workout: dict, device: str) -> dict:
        # An edited workout keeps the key it was first filed under, so a new
        # phone id (a re-pair, a reinstall) replaces it rather than copying it.
        own = str(workout.get("device") or "")
        if _DEVICE_KEY.fullmatch(own):
            device = own
        body = {**workout, "device": device}
        key = self._workout_key(workout["start"], device)
        self._space.put(key, body, description=f"{workout.get('sport_name') or 'Workout'} at {workout['start']}.")
        # History keeps old days' summaries; the workout's day changed.
        from . import history

        history.forget(self, str(workout["start"])[:10])
        return body

    def workouts(self, start: str, end: str, kind: Optional[str] = None) -> list[dict]:
        """Workouts that began in [start, end), oldest first. `kind="strength"`
        keeps only those that carry a strength log."""
        begin, finish = parse_instant(start), parse_instant(end)
        out = []
        for doc in self._space.documents():
            key = str(doc.get("key", ""))
            if not key.startswith(WORKOUT_PREFIX):
                continue
            raw = self._space.get(key)
            if not (isinstance(raw, dict) and raw.get("start")):
                continue
            try:
                began = parse_instant(str(raw["start"]))
                if not begin <= began < finish:
                    continue
            except (TypeError, ValueError):
                # One unreadable workout must not take every day down with it.
                continue
            if kind == "strength" and not isinstance(raw.get("strength"), dict):
                continue
            out.append(raw)
        return sorted(out, key=lambda w: w["start"])

    @staticmethod
    def _route_key(start: Any, device: str) -> str:
        return f"{ROUTE_PREFIX}{device}-{''.join(c for c in str(start) if c.isdigit())}"

    def put_route(self, start: str, device: str, route: dict) -> dict:
        """An outdoor workout's route: `{segments: [[[t, lat, lon, ele, hr, speed], …], …]}`,
        one segment per stretch between pauses. Raises ValueError on a malformed one."""
        segments = route.get("segments") if isinstance(route, dict) else None
        if not isinstance(segments, list) or not all(isinstance(s, list) for s in segments):
            raise ValueError("a route is {\"segments\": [[point, ...], ...]}")
        import math

        def number(v) -> bool:
            return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)

        count = 0
        for segment in segments:
            for point in segment:
                if not (isinstance(point, list) and 3 <= len(point) <= 6
                        and all(number(v) for v in point[:3])
                        and all(v is None or number(v) for v in point[3:])):
                    raise ValueError("a route point is [t, lat, lon, ele, hr, speed]")
                if not (-90 <= point[1] <= 90 and -180 <= point[2] <= 180):
                    raise ValueError("a route point's latitude or longitude is out of range")
                count += 1
        if count > MAX_ROUTE_POINTS:
            raise ValueError(f"a route holds at most {MAX_ROUTE_POINTS} points (thin it first)")
        key = self._route_key(start, device)
        try:
            version = int(route.get("version") or 1)
        except (TypeError, ValueError):
            version = 1
        # The route's own start: its points' times count from it (a ring
        # workout's clock starts a moment after the phone's GPS did).
        own = route.get("start")
        try:
            parse_instant(str(own))
            began = str(own) if own else start
        except (TypeError, ValueError):
            began = start
        body = {"version": version, "start": began, "segments": segments,
                "elevation_source": str(route.get("elevation_source") or "none"), "device": device}
        from jarvis_registry.store import RegistryError

        try:
            self._space.put(key, body, description=f"Route of the workout at {start} ({count} points).")
        except RegistryError as exc:
            raise ValueError(f"the route is too large to keep ({exc}) — thin it first") from exc
        return {"key": key, "points": count}

    def route(self, start: str, device: str) -> Optional[dict]:
        raw = self._space.get(self._route_key(start, device))
        return raw if isinstance(raw, dict) else None

    def delete_workout(self, start: str, device: str) -> bool:
        """Remove one workout (and its route): deleted, or edited so that it now starts elsewhere."""
        self._space.delete_document(self._route_key(start, device))
        gone = self._space.delete_document(self._workout_key(start, device))
        if gone:
            from . import history

            history.forget(self, str(start)[:10])
        return gone

    # ── weight ──────────────────────────────────────────────────────────────
    def put_weights(self, readings: list[dict], device: str) -> int:
        """A scale's readings, each kept once (by id). Returns how many are stored."""
        from . import history

        by_day: dict[str, list[dict]] = {}
        for raw in readings or []:
            reading = _weight_reading(raw)
            by_day.setdefault(reading["at"][:10], []).append(reading)
        stored = 0
        for date, fresh in by_day.items():
            key = f"{WEIGHT_PREFIX}{device}-{date.replace('-', '')}"
            doc = self._space.get(key) or {}
            kept = {r["id"]: r for r in (doc.get("readings") or []) if isinstance(r, dict) and r.get("id")}
            for reading in fresh:
                kept[reading["id"]] = reading
            ordered = sorted(kept.values(), key=lambda r: r["at"])
            self._space.put(key, {"device": device, "date": date, "readings": ordered},
                            description=f"Weigh-ins on {date}.")
            stored += len(fresh)
            history.forget(self, date)
        self._weights_cache = None
        return stored

    def _all_weights(self) -> list[tuple]:
        """Every linked scale's readings, (instant, reading) oldest first — read
        once per store: a year of history asks for them day by day."""
        if getattr(self, "_weights_cache", None) is None:
            unlinked = {d.get("key") for d in self.roster() if not d.get("linked", True)}
            out = []
            for doc in self._space.documents():
                key = str(doc.get("key", ""))
                if not key.startswith(WEIGHT_PREFIX):
                    continue
                body = self._space.get(key) or {}
                device = body.get("device")
                if device in unlinked:
                    continue
                for reading in body.get("readings") or []:
                    try:
                        out.append((parse_instant(reading["at"]), {**reading, "device": device}))
                    except (KeyError, TypeError, ValueError):
                        continue
            out.sort(key=lambda pair: pair[0])
            self._weights_cache = out
        return self._weights_cache

    def weights(self, start: str, end: str) -> list[dict]:
        """Readings taken in [start, end) by linked scales, oldest first, each with its device."""
        begin, finish = parse_instant(start), parse_instant(end)
        return [reading for at, reading in self._all_weights() if begin <= at < finish]

    def latest_weight(self, before: str) -> Optional[dict]:
        """The last reading before `before`, however long ago."""
        found = self.weights("1970-01-01T00:00:00Z", before)
        return found[-1] if found else None

    def first_weight_date(self) -> Optional[str]:
        dates = [str((self._space.get(str(d.get("key"))) or {}).get("date") or "")
                 for d in self._space.documents() if str(d.get("key", "")).startswith(WEIGHT_PREFIX)]
        dates = [d for d in dates if d]
        return min(dates) if dates else None

    # ── strength training ───────────────────────────────────────────────────
    def _documents(self, prefix: str) -> list[dict]:
        out = []
        for doc in self._space.documents():
            key = str(doc.get("key", ""))
            if key.startswith(prefix):
                raw = self._space.get(key)
                if isinstance(raw, dict):
                    out.append(raw)
        return out

    def training(self) -> dict:
        """Templates (in their order), custom exercises and per-exercise settings."""
        templates = sorted(self._documents(TEMPLATE_PREFIX),
                           key=lambda t: (t.get("order") if isinstance(t.get("order"), int) else 0, str(t.get("name", ""))))
        exercises = sorted(self._documents(EXERCISE_PREFIX), key=lambda e: str(e.get("name", "")))
        return {"templates": templates, "exercises": exercises,
                "settings": self._space.get(TRAINING_SETTINGS) or {}}

    def put_template(self, template: dict) -> dict:
        key = TEMPLATE_PREFIX + _training_id(template.get("id"))
        if "order" in template and not isinstance(template["order"], int):
            raise ValueError("a template's order is a whole number")
        self._space.put(key, template, description=f"Workout template {template.get('name') or ''}.".strip())
        return template

    def delete_template(self, template_id: str) -> bool:
        return self._space.delete_document(TEMPLATE_PREFIX + _training_id(template_id))

    def put_exercise(self, exercise: dict) -> dict:
        key = EXERCISE_PREFIX + _training_id(exercise.get("id"))
        self._space.put(key, exercise, description=f"Custom exercise {exercise.get('name') or ''}.".strip())
        return exercise

    def delete_exercise(self, exercise_id: str) -> bool:
        return self._space.delete_document(EXERCISE_PREFIX + _training_id(exercise_id))

    def put_training_settings(self, updates: dict) -> dict:
        """Each named exercise's settings, whole (a field left out is cleared);
        `None` clears them all. Exercises not named are untouched."""
        current = dict(self._space.get(TRAINING_SETTINGS) or {})
        for exercise_id, change in (updates or {}).items():
            if change is None:
                current.pop(exercise_id, None)
            elif isinstance(change, dict):
                current[exercise_id] = dict(change)
        self._space.put(TRAINING_SETTINGS, current, description="Each exercise's rest timers, bar, kind and pinned note.")
        return current

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
