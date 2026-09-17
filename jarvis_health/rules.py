"""Health alerts: thresholds against your own baseline, never a model's opinion.

A rule fires at most once per local day, only on fresh data, and inside quiet
hours it is held rather than dropped — a 2am push about short sleep helps nobody,
but the finding still matters at breakfast.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import Optional

from .metrics import HealthDay, parse_instant
from .scoring import stress_band_shares

#: Every rule on by default; thresholds are what the spec settled on.
DEFAULT_RULES: dict[str, dict] = {
    "resting_hr_high": {"enabled": True, "threshold": 7},      # bpm above baseline
    "hrv_low": {"enabled": True, "threshold": 20},             # percent below baseline
    "spo2_low": {"enabled": True, "threshold": 90},            # percent
    "short_sleep": {"enabled": True, "threshold": 5},          # hours
    "health_low": {"enabled": True, "threshold": 55},          # score
    "stress_sustained": {"enabled": True, "threshold": 60},    # minutes at or above medium
    "battery_low": {"enabled": True, "threshold": 15},         # percent
}

#: Stress at or above this counts towards the sustained-stress rule.
STRESS_MEDIUM = 60

#: Rules that describe the device rather than the body: they wait, never queue.
_DEVICE_RULES = {"battery_low"}


@dataclass
class Alert:
    rule: str
    message: str
    value: Optional[float]
    threshold: Optional[float]
    severity: str = "info"
    hold_until: Optional[str] = None

    def to_json(self, date: str) -> dict:
        return {
            "rule": self.rule,
            "message": self.message,
            "value": self.value,
            "threshold": self.threshold,
            "severity": self.severity,
            "hold_until": self.hold_until,
            "date": date,
        }


def _local(now_utc: str, day: HealthDay) -> tuple[int, int]:
    """The wearer's wall clock at `now_utc`, as (hour, minute)."""
    moment = parse_instant(now_utc) + timedelta(seconds=day.utc_offset)
    return moment.hour, moment.minute


def _minutes(text: str, fallback: int) -> int:
    try:
        hours, _, mins = str(text).partition(":")
        return int(hours) * 60 + int(mins or 0)
    except (TypeError, ValueError):
        return fallback


def in_quiet_hours(now_utc: str, settings: dict, day: Optional[HealthDay] = None) -> bool:
    quiet = (settings or {}).get("quiet_hours") or {}
    start = _minutes(quiet.get("start"), 22 * 60)
    end = _minutes(quiet.get("end"), 8 * 60)
    offset = day.utc_offset if day else -18000
    moment = parse_instant(now_utc) + timedelta(seconds=offset)
    minute = moment.hour * 60 + moment.minute
    return (minute >= start or minute < end) if start > end else (start <= minute < end)


def release_time(settings: dict) -> str:
    quiet = (settings or {}).get("quiet_hours") or {}
    return str(quiet.get("end") or "08:00")


def sustained_high_stress(day: HealthDay) -> int:
    """The longest unbroken stretch of waking minutes at medium stress or above.

    Two things the spec asks for and a sample count cannot give: *sustained*
    means consecutive, so isolated spikes do not add up, and sleep is excluded —
    the ring reads high while you are asleep and there is nothing to alert about.
    """
    series = day.stress
    if series is None or not series.values:
        return 0

    interval = max(1, series.interval_minutes)
    night = day.main_sleep
    asleep: tuple[int, int] | None = None
    if night is not None and night.start and series.start:
        try:
            offset = int((parse_instant(night.start) - parse_instant(series.start)).total_seconds() // 60)
            asleep = (offset, offset + night.time_in_bed_minutes)
        except (TypeError, ValueError):
            asleep = None

    longest = 0
    run = 0
    for index, value in enumerate(series.values):
        minute = index * interval
        if asleep and asleep[0] <= minute <= asleep[1]:
            run = 0
            continue
        if value and value >= STRESS_MEDIUM:
            run += interval
            longest = max(longest, run)
        else:
            # A gap in the readings breaks the stretch as surely as a calm one:
            # nothing was measured, so nothing was sustained.
            run = 0
    return longest


def evaluate(
    day: HealthDay,
    scores: dict,
    baseline,
    settings: dict,
    now_utc: str,
    already_fired: set[str],
    stale: bool = False,
) -> list[Alert]:
    """Which rules fire for this day, in the order they were checked."""
    if stale:
        # Nothing here is worth saying about data we could not refresh.
        return []

    rules = (settings or {}).get("rules") or DEFAULT_RULES
    quiet = in_quiet_hours(now_utc, settings, day)
    hold = release_time(settings) if quiet else None
    out: list[Alert] = []

    def fire(rule: str, message: str, value, threshold, severity="info") -> None:
        if rule in already_fired or not (rules.get(rule) or {}).get("enabled", False):
            return
        out.append(
            Alert(
                rule=rule,
                message=message,
                value=value,
                threshold=threshold,
                severity=severity,
                hold_until=None if rule in _DEVICE_RULES else hold,
            )
        )

    def threshold_for(rule: str, default: float) -> float:
        raw = (rules.get(rule) or {}).get("threshold", default)
        try:
            return float(raw)
        except (TypeError, ValueError):
            return float(default)

    from .baselines import resting_hr

    rhr = resting_hr(day)
    if rhr is not None and baseline.resting_hr:
        limit = threshold_for("resting_hr_high", 7)
        if rhr >= baseline.resting_hr + limit:
            fire(
                "resting_hr_high",
                f"Resting heart rate {round(rhr)} bpm, {round(rhr - baseline.resting_hr)} above your usual "
                f"{round(baseline.resting_hr)}.",
                round(rhr, 1),
                limit,
                "warning",
            )

    hrv_values = day.hrv.nonzero() if day.hrv else []
    if hrv_values and baseline.hrv:
        hrv = sum(hrv_values) / len(hrv_values)
        drop = (baseline.hrv - hrv) / baseline.hrv * 100
        limit = threshold_for("hrv_low", 20)
        if drop >= limit:
            fire(
                "hrv_low",
                f"HRV {round(hrv)}ms, {round(drop)}% below your usual {round(baseline.hrv)}ms.",
                round(hrv, 1),
                limit,
                "warning",
            )

    spo2_values = day.spo2.nonzero() if day.spo2 else []
    if spo2_values:
        low = min(spo2_values)
        limit = threshold_for("spo2_low", 90)
        if low < limit:
            fire("spo2_low", f"Blood oxygen dipped to {round(low)}%.", round(low, 1), limit, "warning")

    night = day.main_sleep
    # A day the scorer calls sleepless has no sleep to complain about: the ring
    # was on a charger, or recorded a nap and nothing else.
    if night is not None and night.asleep_minutes > 0:
        hours = night.asleep_minutes / 60
        limit = threshold_for("short_sleep", 5)
        if hours < limit:
            fire(
                "short_sleep",
                f"{int(night.asleep_minutes // 60)}h {int(night.asleep_minutes % 60)}m of sleep.",
                round(hours, 2),
                limit,
            )

    health = scores.get("health")
    if health is not None and getattr(health, "value", None) is not None:
        limit = threshold_for("health_low", 55)
        if health.value < limit:
            fire("health_low", f"Health score {round(health.value)}.", round(health.value), limit)

    if day.stress and day.stress.values:
        high_minutes = sustained_high_stress(day)
        limit = threshold_for("stress_sustained", 60)
        if high_minutes >= limit:
            fire(
                "stress_sustained",
                f"{high_minutes} unbroken minutes at medium stress or above while awake.",
                high_minutes,
                limit,
            )

    percent = day.battery.get("percent")
    if percent is not None and not day.battery.get("charging"):
        limit = threshold_for("battery_low", 15)
        if float(percent) < limit:
            fire("battery_low", f"Ring battery at {int(percent)}%.", float(percent), limit)

    return out
