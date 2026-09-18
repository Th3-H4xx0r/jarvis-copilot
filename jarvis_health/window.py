"""Days as the body counts them: from falling asleep to falling asleep.

Today runs from last night's bedtime to now; any other day from the bedtime
of the night that ended on it to the bedtime of the next. So the night, what
it charged and the waking day read as one stretch, the hours up past
midnight belong to the day they were lived in, and one day ends exactly
where the next begins — WHOOP's day runs sleep to sleep the same way. A
night that was not recorded leaves that edge at midnight.

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
    first = ordered[0][1]
    # The local midnight before `start` — the phone draws hours from it — even
    # when the day it falls on has no record of its own.
    anchor = next((_local_midnight(date, d) for date, d in ordered
                   if _local_midnight(date, d) <= start < _local_midnight(date, d) + timedelta(days=1)),
                  _midnight_at(start, first.utc_offset))
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

    # Totals, day by day. A day with a steps series counts the slots inside
    # the window; one without (older phones pushed totals only) counts its
    # total in proportion to how much of that day the window covers — never
    # all of it for a sliver. Calories, distance and active minutes exist only
    # per day, so each day's are shared out as its steps were.
    steps, extra = 0.0, {}
    for date, d in ordered:
        day_total = float(d.activity.get("steps") or 0)
        midnight = _local_midnight(date, d)
        covered = max(0.0, (min(end, midnight + timedelta(days=1)) - max(start, midnight)).total_seconds()) / 86400
        if d.steps and d.steps.start and d.steps.values:
            origin, interval = parse_instant(d.steps.start), max(1, d.steps.interval_minutes)
            counted = sum(float(v or 0) for i, v in enumerate(d.steps.values)
                          if start <= origin + timedelta(minutes=i * interval) < end)
        else:
            counted = day_total * covered
        share = (counted / day_total) if day_total else covered
        steps += counted
        for key in ("active_minutes", "kilocalories", "distance_meters"):
            value = float(d.activity.get(key) or 0)
            if value:
                extra[key] = extra.get(key, 0.0) + value * share
    out.activity = {"steps": int(round(steps)), **{k: round(v, 1) for k, v in extra.items()}}
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
                    utc_offset: int, live: bool = True) -> dict:
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
    # Points are slot ends: the one at or before bedtime opens the window, and
    # the slot still running (stamped at its end, just past now) is the level
    # now. A finished day stops at its own end, before the next night's charge.
    opens = start - timedelta(minutes=SLOT)
    closes = end + (timedelta(minutes=SLOT) if live else timedelta(seconds=1))
    curve = sorted((p for p in points.values() if opens < parse_instant(p["at"]) < closes),
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


def _night(day: Optional[HealthDay]) -> Optional[SleepSession]:
    """A day's night: its main sleep, when there was one."""
    night = day.main_sleep if day else None
    return night if night and night.start and night.end and night.asleep_minutes >= MAIN_SLEEP else None


def _window(store, days: dict, start: datetime, end: datetime, night: Optional[SleepSession],
            utc_offset: int, live: bool) -> dict:
    """The window's day, its stats and the battery across it."""
    within = {date: d for date, d in days.items()
              if _local_midnight(date, d) + timedelta(days=1) > start and _local_midnight(date, d) <= end}
    wday = window_day(within, start, end) if within and end > start else None
    return {
        "start": _iso(start),
        "end": _iso(end),
        "wake": night.end if night else None,
        "no_wake": night is None,
        "minutes": max(0, int((end - start).total_seconds() // 60)),
        "day": to_json(wday) if wday else None,
        "stats": window_stats(wday) if wday else {},
        "battery": _window_battery(store, start, end, night, utc_offset, live=live),
    }


def today(store, now: str) -> dict:
    """From falling asleep last night to now: the window's day, its stats, the battery.

    `date` is the day it belongs to — the one last night ended on — which is
    still yesterday's date at 1 AM before bed.
    """
    from .merge import merged_day

    moment = parse_instant(now)
    days = {date: merged_day(store, date) for date in store.dates(5)}
    days = {date: d for date, d in days.items() if d is not None}
    night = last_night(list(days.values()), moment)
    if night is not None and moment - parse_instant(night.end) > LAST_NIGHT:
        night = None
    offset = days[max(days)].utc_offset if days else 0
    start = parse_instant(night.start) if night else _midnight_at(moment, offset)
    out = _window(store, days, start, moment, night, offset, live=True)
    out["end"] = now
    out["utc_offset"] = offset
    anchor = parse_instant(night.end) if night else moment
    out["date"] = (anchor + timedelta(seconds=offset)).date().isoformat()
    return out


def cycle(store, date: str, now: str) -> dict:
    """One day, bedtime to bedtime: from the night that ended on `date` to the next one."""
    from .merge import merged_day

    moment = parse_instant(now)
    first = datetime.strptime(date, "%Y-%m-%d").date()
    names = [(first + timedelta(days=k)).isoformat() for k in (-1, 0, 1)]
    days = {name: merged_day(store, name) for name in names}
    days = {name: d for name, d in days.items() if d is not None}
    own = days.get(date)
    offset = own.utc_offset if own else next((d.utc_offset for d in days.values()), 0)
    midnight = (_local_midnight(date, own) if own
                else parse_instant(f"{date}T00:00:00Z") - timedelta(seconds=offset))
    night, following = _night(own), _night(days.get(names[2]))
    start = parse_instant(night.start) if night else midnight
    end = min(moment, parse_instant(following.start) if following else midnight + timedelta(days=1))
    out = _window(store, days, start, max(start, end), night, offset, live=end >= moment)
    out["date"] = date
    return out
