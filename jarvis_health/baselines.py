"""Your own normal: medians over the days already stored.

Nothing here compares you to a population. A baseline needs a handful of days
before it means anything, which is why `Baseline.is_ready` gates recovery.
"""
from __future__ import annotations

import math
from statistics import median
from typing import Optional

from .metrics import Baseline, HealthDay, parse_instant


def resting_hr(day: HealthDay) -> Optional[float]:
    """The lowest ten-minute mean inside the night.

    Ten *contiguous* minutes, not ten readings that happen to sit next to each
    other in the list: the ring writes a zero for "no reading", and averaging
    two lone samples two hours apart would report a dip that never happened.
    """
    night = day.main_sleep
    series = day.heart_rate
    if night is None or series is None or not series.values or not series.start:
        return None

    try:
        start = parse_instant(series.start)
        first = int((parse_instant(night.start) - start).total_seconds() // 60)
    except (TypeError, ValueError):
        # A session the device sent without a usable start: no window to read.
        return None

    last = first + night.time_in_bed_minutes
    interval = max(1, series.interval_minutes)
    window = max(10, interval)

    samples = [
        (index * interval, float(value))
        for index, value in enumerate(series.values)
        if value and value > 0 and first <= index * interval <= last
    ]
    if not samples:
        return None

    means: list[float] = []
    for i, (minute, _) in enumerate(samples):
        # Walk forward only while the readings stay gapless: a missing sample
        # ends the window, because unmeasured minutes were not quiet ones.
        run: list[float] = []
        previous = minute
        for m, value in samples[i:]:
            if m - previous > interval:
                break
            if m - minute > window:
                break
            run.append(value)
            previous = m
        span = previous - minute
        if span < window and interval < window:
            continue
        means.append(sum(run) / len(run))

    return round(min(means), 1) if means else None


def bedtime_minute(day: HealthDay) -> Optional[float]:
    """When the night began, as a local minute of day."""
    night = day.main_sleep
    if night is None or not night.start:
        return None
    started = parse_instant(night.start)
    local = started.timestamp() + day.utc_offset
    return int(local % 86400 // 60)


def bedtime_minute_median(values: list[float]) -> Optional[float]:
    """Median bedtime that survives midnight.

    Minutes-of-day are angles, not magnitudes: 23:30 and 00:30 are an hour apart,
    not twenty-three. Averaging them as numbers puts "usual bedtime" at lunchtime.
    """
    if not values:
        return None
    angles = [v / 1440 * 2 * math.pi for v in values]
    x = sum(math.cos(a) for a in angles) / len(angles)
    y = sum(math.sin(a) for a in angles) / len(angles)
    if abs(x) < 1e-9 and abs(y) < 1e-9:
        return median(values)
    minute = (math.atan2(y, x) % (2 * math.pi)) / (2 * math.pi) * 1440
    # Snap to the nearest recorded bedtime so the answer is a real one.
    return min(values, key=lambda v: min(abs(v - minute), 1440 - abs(v - minute)))


def baseline_from(days: list[HealthDay], window: int = 14) -> Baseline:
    recent = [d for d in sorted(days, key=lambda d: d.date, reverse=True)][:window]
    if not recent:
        return Baseline(window=window)

    hrvs = [v for d in recent for v in ((_mean(d.hrv.nonzero()) if d.hrv else None),) if v]
    rhrs = [v for d in recent for v in (resting_hr(d),) if v]
    bedtimes = [v for d in recent for v in (bedtime_minute(d),) if v is not None]
    sleeps = [d.main_sleep.asleep_minutes for d in recent if d.main_sleep]
    temps = [v for d in recent for v in ((_mean(d.temperature.nonzero()) if d.temperature else None),) if v]

    return Baseline(
        hrv=median(hrvs) if hrvs else None,
        resting_hr=median(rhrs) if rhrs else None,
        hrv_days=len(hrvs),
        resting_hr_days=len(rhrs),
        bedtime_minute=bedtime_minute_median(bedtimes),
        sleep_minutes=median(sleeps) if sleeps else None,
        temperature=median(temps) if temps else None,
        days_used=len(recent),
        window=window,
    )


def _mean(values: list[float]) -> Optional[float]:
    return (sum(values) / len(values)) if values else None
