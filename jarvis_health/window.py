"""Since you woke: stats that do not reset at midnight.

The window runs from the end of the last main sleep to now, across as many
midnights as it spans. Its series are anchored at the local midnight of the
day it began, so a minute past midnight is minute 1440, not minute 0 — the
phone's charts draw it as one continuous stretch.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Optional

from .battery import MAIN_SLEEP, SLOT, band as battery_band
from .metrics import HealthDay, Series, _iso, parse_instant, to_json
from .scoring import stress_band_shares

WINDOW_METRICS = ("heart_rate", "hrv", "stress", "spo2", "temperature", "steps")


def last_wake(days: list[HealthDay], now: datetime) -> Optional[datetime]:
    """The end of the most recent main sleep (≥ 3 h asleep) before now. Naps don't count."""
    ends = [parse_instant(s.end) for d in days for s in d.sleep
            if s.end and s.asleep_minutes >= MAIN_SLEEP and parse_instant(s.end) <= now]
    return max(ends) if ends else None


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

    # Naps inside the window; the night that opened it is outside by definition.
    out.sleep = [s for _, d in ordered for s in d.sleep
                 if s.end and start <= parse_instant(s.end) <= end and s.asleep_minutes < MAIN_SLEEP]

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


def since_wake(store, now: str) -> dict:
    """Everything since the last wake: the window's day, its stats, and the battery over it."""
    from .merge import merged_day

    moment = parse_instant(now)
    days = {date: merged_day(store, date) for date in store.dates(5)}
    days = {date: d for date, d in days.items() if d is not None}
    wake = last_wake(list(days.values()), moment)
    if wake is not None:
        start = wake
    elif days:
        newest = max(days)
        start = _local_midnight(newest, days[newest])
    else:
        start = moment.replace(hour=0, minute=0, second=0, microsecond=0)

    within = {date: d for date, d in days.items()
              if _local_midnight(date, d) + timedelta(days=1) > start and _local_midnight(date, d) <= moment}
    wday = window_day(within, start, moment) if within else None
    curve = [p for date in sorted(within) for p in ((store.battery(date) or {}).get("curve") or [])
             if start <= parse_instant(p["at"]) <= moment]
    level = curve[-1]["level"] if curve else None
    wake_level = curve[0]["level"] if curve else None
    return {
        "start": _iso(start),
        "end": now,
        "no_wake": wake is None,
        "minutes": int((moment - start).total_seconds() // 60),
        "day": to_json(wday) if wday else None,
        "stats": window_stats(wday) if wday else {},
        "battery": {
            "level": level,
            "wake_level": wake_level,
            "band": battery_band(level),
            "drained": round(wake_level - level, 1) if curve else None,
            "biggest_drain": _biggest_drain(curve),
            "curve": curve,
        },
    }
