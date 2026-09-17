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
    """The lowest rolling ten-minute mean inside the night.

    A single low sample is noise; ten quiet minutes is a resting heart rate.
    """
    night = day.main_sleep
    series = day.heart_rate
    if night is None or series is None or not series.values:
        return None

    start = parse_instant(series.start)
    first = int((parse_instant(night.start) - start).total_seconds() // 60)
    last = first + night.time_in_bed_minutes
    window = max(1, 10 // max(1, series.interval_minutes))

    samples = [
        (index * series.interval_minutes, value)
        for index, value in enumerate(series.values)
        if value and value > 0 and first <= index * series.interval_minutes <= last
    ]
    if len(samples) < window:
        return None

    means = [
        sum(v for _, v in samples[i : i + window]) / window
        for i in range(0, len(samples) - window + 1)
    ]
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
        bedtime_minute=bedtime_minute_median(bedtimes),
        sleep_minutes=median(sleeps) if sleeps else None,
        temperature=median(temps) if temps else None,
        days_used=len(recent),
        window=window,
    )


def _mean(values: list[float]) -> Optional[float]:
    return (sum(values) / len(values)) if values else None
