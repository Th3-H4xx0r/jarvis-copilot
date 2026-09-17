"""Scores, and the contributions that explain them.

Every contributor is a linear ramp between a target band and the bounds where it
earns nothing, so a score is never a black box: it can always be read back as
"you lost N of M points on X". Weights are this project's, not a vendor's; the
contributor *sets* follow what the wearable industry publishes (Oura's sleep
contributors, Whoop's baseline-relative recovery, Garmin's four stress bands).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from .metrics import Baseline, HealthDay

#: Share of the health score each part carries when it is present.
WEIGHTS = {"sleep": 0.35, "recovery": 0.35, "body": 0.20, "activity": 0.10}

BANDS = ((85, "Excellent"), (70, "Good"), (55, "Fair"), (0, "Low"))

#: Stress 0-100 split the way the ring's own app and Garmin both split it.
STRESS_BANDS = (("Relax", 0, 29), ("Normal", 30, 59), ("Medium", 60, 79), ("High", 80, 100))


@dataclass
class Contribution:
    name: str
    earned: float
    possible: float
    detail: str = ""


@dataclass
class Score:
    value: Optional[float] = None
    points: list[Contribution] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)

    def to_json(self) -> dict:
        # Band from the *published* number: "85 · Good" would be a contradiction
        # on the card, and the table says 85 is Excellent.
        shown = None if self.value is None else round(self.value)
        return {
            "value": shown,
            "band": band(shown),
            "points": [
                {"name": c.name, "earned": round(c.earned, 1), "possible": c.possible, "detail": c.detail}
                for c in self.points
            ],
            "missing": list(self.missing),
        }


def band(value: Optional[float]) -> str:
    if value is None:
        return "—"
    for floor, name in BANDS:
        if value >= floor:
            return name
    return "Low"


def ramp(
    value: Optional[float],
    full_low: float,
    full_high: float,
    zero_low: float,
    zero_high: float,
    points: float,
) -> float:
    """Full marks inside [full_low, full_high], nothing at or past the zero bounds.

    Between the two it falls off linearly, which keeps a score explainable: half
    the distance from the target to the bound costs half the points.
    """
    if value is None:
        return 0.0
    if full_low <= value <= full_high:
        return float(points)
    if value < full_low:
        if value <= zero_low:
            return 0.0
        return points * (value - zero_low) / (full_low - zero_low)
    if value >= zero_high:
        return 0.0
    return points * (zero_high - value) / (zero_high - full_high)


def _score(points: list[Contribution]) -> Score:
    total = sum(c.possible for c in points)
    earned = sum(c.earned for c in points)
    return Score(value=(earned / total * 100) if total else None, points=points)


def sleep_score(day: HealthDay, baseline: Baseline) -> Score:
    """Oura's contributor set, our weights, all of them shown to the reader."""
    night = day.main_sleep
    if night is None or night.asleep_minutes <= 0:
        return Score(None, [], ["sleep"])

    asleep = night.asleep_minutes
    hours = asleep / 60
    points = [
        Contribution("Duration", ramp(hours, 7, 9, 3, 12, 30), 30, f"{int(asleep // 60)}h {int(asleep % 60)}m"),
        Contribution(
            "Efficiency",
            ramp(night.efficiency * 100, 90, 100, 60, 101, 15),
            15,
            f"{round(night.efficiency * 100)}%",
        ),
    ]

    deep_share = night.stage_minutes(2) / asleep * 100
    rem_share = night.stage_minutes(4) / asleep * 100
    points.append(Contribution("Deep sleep", ramp(deep_share, 13, 23, 3, 40, 15), 15, f"{round(deep_share)}%"))
    points.append(Contribution("REM sleep", ramp(rem_share, 20, 25, 5, 45, 15), 15, f"{round(rem_share)}%"))

    # Two ways a night is restless; the worse one decides, so a single long stir
    # and six brief ones are both penalised.
    by_count = ramp(night.awakenings, 0, 1, -1, 6, 15)
    by_minutes = ramp(night.awake_minutes, 0, 10, -1, 60, 15)
    points.append(
        Contribution(
            "Restfulness",
            min(by_count, by_minutes),
            15,
            f"{night.awakenings} waking{'s' if night.awakenings != 1 else ''}, {night.awake_minutes}m awake",
        )
    )

    bedtime = _bedtime_minute(night, day)
    if baseline.bedtime_minute is None or bedtime is None:
        points.append(Contribution("Timing", 10, 10, "no bedtime baseline yet"))
    else:
        off = _minutes_apart(bedtime, baseline.bedtime_minute)
        points.append(Contribution("Timing", ramp(off, 0, 30, -1, 180, 10), 10, f"{round(off)}m from usual"))

    return _score(points)


def recovery_score(day: HealthDay, baseline: Baseline) -> Score:
    """Whoop's principle: every input against your own baseline, never a norm."""
    if not baseline.is_ready:
        return Score(None, [], ["baseline"])

    points: list[Contribution] = []
    hrv = _mean(day.hrv.nonzero()) if day.hrv else None
    if hrv is not None and baseline.hrv:
        points.append(
            Contribution(
                "HRV",
                ramp(hrv, baseline.hrv, 1e9, baseline.hrv * 0.6, 1e9, 50),
                50,
                f"{round(hrv)}ms vs {round(baseline.hrv)}ms",
            )
        )

    from .baselines import resting_hr

    rhr = resting_hr(day)
    if rhr is not None and baseline.resting_hr:
        points.append(
            Contribution(
                "Resting HR",
                ramp(rhr, -1e9, baseline.resting_hr, -1e9, baseline.resting_hr + 12, 30),
                30,
                f"{round(rhr)} bpm vs {round(baseline.resting_hr)}",
            )
        )

    # Sleep is context here, not evidence: it already carries its own weight in
    # the health score, so on its own it cannot stand in for recovery.
    if not points:
        return Score(None, [], ["hrv", "resting_hr"])

    sleep = sleep_score(day, baseline)
    if sleep.value is not None:
        points.append(Contribution("Sleep", sleep.value / 100 * 20, 20, f"sleep score {round(sleep.value)}"))

    return _score(points)


def body_score(day: HealthDay, baseline: Baseline) -> Score:
    points: list[Contribution] = []

    if day.stress and day.stress.nonzero():
        shares = stress_band_shares(day.stress.nonzero())
        calm = shares["Relax"] + shares["Normal"]
        points.append(Contribution("Stress", ramp(calm, 85, 100, 40, 101, 50), 50, f"{round(calm)}% calm"))

    if day.spo2 and day.spo2.nonzero():
        low = min(day.spo2.nonzero())
        points.append(Contribution("SpO₂", ramp(low, 95, 100, 88, 101, 30), 30, f"low {round(low)}%"))

    if day.temperature and day.temperature.nonzero() and baseline.temperature:
        off = abs(_mean(day.temperature.nonzero()) - baseline.temperature)
        points.append(Contribution("Temperature", ramp(off, 0, 0.3, -1, 1.5, 20), 20, f"{off:.1f}°C off"))

    return _score(points) if points else Score(None, [], ["body"])


def activity_score(day: HealthDay, goals: dict) -> Score:
    steps_goal = float(goals.get("steps") or 0)
    minutes_goal = float(goals.get("active_minutes") or 0)
    points: list[Contribution] = []

    steps = float(day.activity.get("steps") or 0)
    if steps_goal > 0:
        points.append(Contribution("Steps", min(1.0, steps / steps_goal) * 60, 60, f"{int(steps)}"))
    minutes = float(day.activity.get("active_minutes") or 0)
    if minutes_goal > 0:
        points.append(Contribution("Active minutes", min(1.0, minutes / minutes_goal) * 40, 40, f"{int(minutes)}m"))

    return _score(points) if points else Score(None, [], ["activity"])


def health_score(parts: dict[str, Score]) -> Score:
    """The four parts, weighted — renormalised over whichever ones exist."""
    present = {name: score for name, score in parts.items() if score.value is not None}
    missing = [name for name, score in parts.items() if score.value is None]
    if not present:
        return Score(None, [], missing)

    total_weight = sum(WEIGHTS.get(name, 0) for name in present) or 1
    value = sum(score.value * WEIGHTS.get(name, 0) for name, score in present.items()) / total_weight
    points = [
        Contribution(name.title(), score.value * WEIGHTS.get(name, 0) / total_weight, WEIGHTS.get(name, 0) * 100 / total_weight, band(score.value))
        for name, score in present.items()
    ]
    return Score(value=value, points=points, missing=missing)


def stress_band_shares(values: list[float]) -> dict[str, float]:
    """Percentage of the day's stress readings in each band.

    The ring's samples are raw bytes, so a garbled one can land outside 0–100
    and a real one can be fractional. Anything off the scale is not a reading
    and leaves the denominator, which keeps the four shares summing to 100.
    """
    shares = {name: 0.0 for name, _, _ in STRESS_BANDS}
    counted = 0
    for value in values:
        if value is None or value < 0 or value > 100:
            continue
        counted += 1
        for name, low, high in STRESS_BANDS:
            if low <= value < high + 1:
                shares[name] += 1
                break
    if not counted:
        return shares
    return {name: count / counted * 100 for name, count in shares.items()}


def _mean(values: list[float]) -> Optional[float]:
    return (sum(values) / len(values)) if values else None


def _bedtime_minute(night, day: HealthDay) -> Optional[float]:
    from .baselines import bedtime_minute

    return bedtime_minute(day)


def _minutes_apart(a: float, b: float) -> float:
    """Distance between two minutes-of-day, the short way round the clock."""
    gap = abs(a - b) % 1440
    return min(gap, 1440 - gap)
