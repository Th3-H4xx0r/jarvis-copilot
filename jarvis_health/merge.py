"""One day of the person, from however many wearables reported it.

The primary wearable supplies what a body is judged on — sleep, heart, HRV,
stress, SpO₂, temperature. Another device fills in only what the primary does
not have. Steps take the highest count, because every device undercounts.
"""
from __future__ import annotations

import copy
from typing import Optional

from .metrics import HealthDay

#: Judged from one device at a time: mixing two rings' heart rates would read
#: as a heart that jumps between them.
PRIMARY_METRICS = ("heart_rate", "hrv", "stress", "spo2", "temperature")


def primary_device(settings: dict, days: dict[str, HealthDay]) -> Optional[str]:
    """The chosen primary if it reported, else the first roster device with sleep or heart rate."""
    chosen = settings.get("primary_device") or ""
    if chosen in days:
        return chosen
    for entry in settings.get("devices") or []:
        found = days.get(entry.get("key"))
        if found and (found.sleep or found.has("heart_rate")):
            return entry["key"]
    return next(iter(days), None)


def merged_day(store, date: str) -> Optional[HealthDay]:
    """The linked wearables' records for `date`, as one day. None when none reported."""
    linked = {e.get("key") for e in store.linked()}
    days = {k: d for k, d in store.device_days(date).items() if k in linked}
    if not days:
        return None
    primary = primary_device(store.settings(), days)
    base = copy.deepcopy(days[primary])
    for key, other in days.items():
        if key == primary:
            continue
        if not base.sleep and other.sleep:
            base.sleep = copy.deepcopy(other.sleep)
        for metric in PRIMARY_METRICS:
            if not base.has(metric) and other.has(metric):
                setattr(base, metric, copy.deepcopy(getattr(other, metric)))
        if (other.activity.get("steps") or 0) > (base.activity.get("steps") or 0):
            base.activity = dict(other.activity)
            base.steps = copy.deepcopy(other.steps)
    base.source = primary
    return base


def merged_recent(store, count: int = 14) -> list[HealthDay]:
    """The newest merged days, newest first."""
    out = [merged_day(store, date) for date in store.dates(count)]
    return [d for d in out if d is not None]
