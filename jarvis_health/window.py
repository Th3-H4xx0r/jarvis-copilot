"""Today, the way the body counts it: from falling asleep last night to now.

One stretch rather than two: last night's sleep, the charge it put back and
the waking day since, on one timeline that does not reset at midnight —
WHOOP's day runs sleep to sleep the same way. With no night in the last day
(the ring was off) it is the calendar day so far.

Series are anchored at the local midnight of the day the window began, so a
minute past the next midnight is minute 1440, not minute 0 — the phone's
charts draw it as one continuous stretch.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Optional

from .battery import MAIN_SLEEP, SLOT, band as battery_band
from .metrics import HealthDay, Series, SleepSession, _iso, parse_instant, to_json
from .scoring import stress_band_shares

WINDOW_METRICS = ("heart_rate", "hrv", "stress", "spo2", "temperature", "steps")

#: A night that ended longer ago than this is not last night: the ring was off
#: for it, so today starts at midnight instead.
LAST_NIGHT = timedelta(hours=24)


def last_night(days: list[HealthDay], now: datetime) -> Optional[SleepSession]:
    """The most recent main sleep (≥ 3 h asleep) that has ended by now. Naps don't count."""
    nights = [s for d in days for s in d.sleep
              if s.start and s.end and s.asleep_minutes >= MAIN_SLEEP and parse_instant(s.end) <= now]
    return max(nights, key=lambda s: parse_instant(s.end), default=None)


def _midnight_at(moment: datetime, utc_offset: int) -> datetime:
    """The local midnight on or before `moment`, as UTC."""
    local = moment + timedelta(seconds=utc_offset)
    return local.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(seconds=utc_offset)


def _local_midnight(date: str, day: HealthDay) -> datetime:
    for name in WINDOW_METRICS:
        series = getattr(day, name)
        if series and series.start:
            return parse_instant(series.start)
    return parse_instant(f"{date}T00:00:00Z") - timedelta(seconds=day.utc_offset)


def window_day(days: dict[str, HealthDay], start: datetime, end: datetime) -> HealthDay:
    """One day covering [start, end): series zero outside it, anchored at start's local midnight."""
    ordered = sorted(days.items())
    anchor = next((_local_midnight(date, d) for date, d in ordered
                   if _local_midnight(date, d) <= start < _local_midnight(date, d) + timedelta(days=1)),
                  start.replace(minute=0, second=0, microsecond=0))
    first = ordered[0][1]
    out = HealthDay(date=ordered[0][0], timezone=first.timezone, utc_offset=first.utc_offset, source="window")

    for name in WINDOW_METRICS:
        interval = next((getattr(d, name).interval_minutes for _, d in ordered
                         if getattr(d, name) and getattr(d, name).interval_minutes), 0)
        if not interval:
            continue
        values = [0.0] * max(0, math.ceil((end - anchor).total_seconds() / 60 / interval))
        for _, d in ordered:
            series = getattr(d, name)
            if not series or not series.start:
                continue
            origin = parse_instant(series.start)
            for i, v in enumerate(series.values):
                moment = origin + timedelta(minutes=i * series.interval_minutes)
                if start <= moment < end:
                    index = int((moment - anchor).total_seconds() // 60 // interval)
                    if 0 <= index < len(values):
                        values[index] = float(v or 0)
        setattr(out, name, Series(start=_iso(anchor), interval_minutes=interval, values=values))

    # The night that opened the window (it ends where the window starts) and
    # any naps inside it: the sleep card shows how you slept before this day.
    out.sleep = [s for _, d in ordered for s in d.sleep
                 if s.end and start <= parse_instant(s.end) <= end]

    # Totals: steps are summed from the window's own slots; calories, distance
    # and active minutes only exist per day, so they are shared out by steps.
    # A wearable that sends no per-slot steps (older phones) gets its day
    # totals instead: near enough, since a day's steps before waking are few.
    day_steps = sum(float(d.activity.get("steps") or 0) for _, d in ordered)
    steps = sum(out.steps.nonzero()) if out.steps else day_steps
    share = (steps / day_steps) if day_steps else 0.0
    out.activity = {"steps": int(steps)}
    for key in ("active_minutes", "kilocalories", "distance_meters"):
        total = sum(float(d.activity.get(key) or 0) for _, d in ordered)
        if total:
            out.activity[key] = round(total * share, 1)
    return out


def _avg(values: list[float]) -> Optional[float]:
    return round(sum(values) / len(values), 1) if values else None


def window_stats(day: HealthDay) -> dict:
    hr = day.heart_rate.nonzero() if day.heart_rate else []
    stress = day.stress.nonzero() if day.stress else []
    spo2 = day.spo2.nonzero() if day.spo2 else []
    return {
        **day.activity,
        "hr_avg": _avg(hr), "hr_max": max(hr) if hr else None, "hr_min": min(hr) if hr else None,
        "stress_avg": _avg(stress), "stress_shares": stress_band_shares(stress) if stress else {},
        "hrv_avg": _avg(day.hrv.nonzero()) if day.hrv else None,
        "spo2_low": min(spo2) if spo2 else None,
        "temperature_avg": _avg(day.temperature.nonzero()) if day.temperature else None,
    }


def _biggest_drain(curve: list[dict]) -> Optional[dict]:
    """The steepest single slot: the largest drop between points 30 minutes apart."""
    worst = None
    for before, after in zip(curve, curve[1:]):
        gap = (parse_instant(after["at"]) - parse_instant(before["at"])).total_seconds() / 60
        drop = before["level"] - after["level"]
        if gap <= SLOT and drop > 0 and (worst is None or drop > worst["points"]):
            worst = {"start": before["at"], "end": after["at"], "points": round(drop, 1)}
    return worst


def _window_battery(store, start: datetime, end: datetime, night: Optional[SleepSession],
                    utc_offset: int) -> dict:
    """The battery across the window: the level at bedtime, the night's charge, the day's drain.

    Read from the stored daily curves. The point at or before bedtime opens
    it — the curve's points are slot ends — and a day charted again later
    overrides the same instant in an older one.
    """
    first = (start + timedelta(seconds=utc_offset)).date() - timedelta(days=1)
    last = (end + timedelta(seconds=utc_offset)).date()
    dates = [(first + timedelta(days=k)).isoformat() for k in range((last - first).days + 1)]
    points: dict = {}
    for date in dates:
        for p in (store.battery(date) or {}).get("curve") or []:
            points[p["at"]] = p
    opens = start - timedelta(minutes=SLOT)
    curve = sorted((p for p in points.values() if opens < parse_instant(p["at"]) <= end),
                   key=lambda p: parse_instant(p["at"]))
    level = curve[-1]["level"] if curve else None

    wake = parse_instant(night.end) if night else None
    record = store.battery((((wake or end) + timedelta(seconds=utc_offset)).date()).isoformat()) or {}
    out = {
        "level": level,
        "band": battery_band(level),
        "curve": curve,
        "biggest_drain": _biggest_drain(curve),
        "bed_at": night.start if night else None,
        "wake_at": night.end if night else None,
        "bed_level": None, "wake_level": None, "charged": None, "drained": None,
        "no_sleep": night is None,
        "recovery_factor": record.get("recovery_factor") if night else None,
        "calibrating": record.get("calibrating"),
        "partial": record.get("partial"),
    }
    if not curve:
        return out
    if night is None:
        out["drained"] = round(max(0.0, curve[0]["level"] - level), 1)
        return out
    woke = next((p["level"] for p in curve if parse_instant(p["at"]) >= wake), None)
    out["bed_level"] = curve[0]["level"]
    if woke is not None:
        out["wake_level"] = woke
        out["charged"] = round(max(0.0, woke - curve[0]["level"]), 1)
        out["drained"] = round(max(0.0, woke - level), 1)
    return out


def today(store, now: str) -> dict:
    """Everything from falling asleep last night to now: the window's day, its stats, the battery."""
    from .merge import merged_day

    moment = parse_instant(now)
    days = {date: merged_day(store, date) for date in store.dates(5)}
    days = {date: d for date, d in days.items() if d is not None}
    night = last_night(list(days.values()), moment)
    if night is not None and moment - parse_instant(night.end) > LAST_NIGHT:
        night = None
    offset = days[max(days)].utc_offset if days else 0
    start = parse_instant(night.start) if night else _midnight_at(moment, offset)

    within = {date: d for date, d in days.items()
              if _local_midnight(date, d) + timedelta(days=1) > start and _local_midnight(date, d) <= moment}
    wday = window_day(within, start, moment) if within else None
    return {
        "start": _iso(start),
        "end": now,
        "wake": night.end if night else None,
        "no_wake": night is None,
        "minutes": int((moment - start).total_seconds() // 60),
        "day": to_json(wday) if wday else None,
        "stats": window_stats(wday) if wday else {},
        "battery": _window_battery(store, start, moment, night, offset),
    }
