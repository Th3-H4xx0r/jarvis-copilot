"""Body Battery: a reservoir sleep fills and the waking day drains.

Modelled on Garmin/Firstbeat — charge while asleep, drain with stress and
effort, only sleep charges substantially — and judged the way WHOOP judges
recovery: every input against your own baseline, never a population. Pure
functions over stored days; the runner stores each day's curve, so tomorrow's
charge starts from tonight's real level.

The drain rates are tuned to the design's acceptance test, a typical day
draining 45–65 points (e.g. 85 at wake to 30 at bedtime).
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

from .baselines import resting_hr, sleeping_hrv
from .metrics import Baseline, HealthDay, Series, _iso, parse_instant

FLOOR, CEIL, FIRST_LEVEL = 5.0, 100.0, 50.0
#: A full, good night adds up to this (Garmin: 40–60 on a real night).
MAX_CHARGE = 65.0
#: Until a week of nights has built the HRV baseline, recovery cannot be judged,
#: so a night cannot charge the battery fully.
CALIBRATING_CAP, CALIBRATION_NIGHTS = 50.0, 7
SLEEP_NEED = 480.0
#: Asleep at least this long is a night; less is a nap.
MAIN_SLEEP = 180
NAP_RATE = 0.5
SLOT = 30
#: The smallest worthwhile change in log-HRV, in SDs (Plews/Buchheit).
SWC = 0.5

#: Per 30-minute slot.
AWAKE_DRAIN = 1.0
STRESS_DRAIN = 2.0
REST_GAIN = 0.25

BANDS = ((76, "High"), (51, "Medium"), (26, "Low"), (0, "Very low"))

#: More than this share of waking slots with nothing measured is "partial data".
PARTIAL_SHARE = 0.25


def band(level: Optional[float]) -> str:
    if level is None:
        return "—"
    return next(name for floor, name in BANDS if level >= floor)


def sleep_debt(prior_nights: list[int]) -> float:
    """Minutes short of the base need over up to three prior nights."""
    return float(sum(max(0.0, SLEEP_NEED - m) for m in prior_nights[:3]))


def sleep_need(debt: float) -> float:
    """WHOOP's rule: last nights' shortfall raises tonight's need (half of it, up to 2 h)."""
    return SLEEP_NEED + min(120.0, 0.5 * max(0.0, debt))


def recovery_factor(hrv: Optional[float], rhr: Optional[float], baseline: Baseline) -> float:
    """0.5–1.15: tonight's HRV and resting heart rate against your own baseline.

    HRV only counts outside the smallest worthwhile change, so ordinary
    night-to-night noise leaves the factor at 1.
    """
    factor = 1.0
    if hrv and baseline.ln_hrv_mean is not None and baseline.ln_hrv_sd:
        z = (math.log(hrv) - baseline.ln_hrv_mean) / baseline.ln_hrv_sd
        if abs(z) > SWC:
            factor += 0.12 * (z - math.copysign(SWC, z))
    if rhr and baseline.resting_hr:
        diff = rhr - baseline.resting_hr
        if diff > 2:
            factor -= 0.03 * (diff - 2)
        elif diff < -2:
            factor += 0.02 * (-diff - 2)
    return round(min(1.15, max(0.5, factor)), 3)


@dataclass
class Charge:
    points: float = 0.0
    performance: float = 0.0
    factor: float = 1.0
    need: float = SLEEP_NEED
    calibrating: bool = False
    no_sleep: bool = False


def overnight_charge(day: HealthDay, baseline: Baseline, prior_nights: list[int]) -> Charge:
    """What last night put back: sleep performance × recovery, up to 65."""
    calibrating = baseline.hrv_nights < CALIBRATION_NIGHTS
    night = day.main_sleep
    if night is None or night.asleep_minutes < MAIN_SLEEP:
        return Charge(calibrating=calibrating, no_sleep=True)
    need = sleep_need(sleep_debt(prior_nights))
    performance = min(1.0, night.asleep_minutes / need)
    factor = recovery_factor(sleeping_hrv(day), resting_hr(day), baseline)
    points = MAX_CHARGE * performance * factor
    if calibrating:
        points = min(points, CALIBRATING_CAP)
    return Charge(round(points, 1), round(performance, 3), factor, need, calibrating)


def slot_drain(stress, hr, steps, rest_hr: float, hr_max: float) -> tuple[float, dict]:
    """Points one 30-minute awake slot costs, and what took them.

    Nothing measured (the ring off, or out of range) costs being awake only.
    """
    if stress is None and hr is None and steps is None:
        return AWAKE_DRAIN, {"awake": AWAKE_DRAIN}
    parts = {"awake": AWAKE_DRAIN, "stress": 0.0, "activity": 0.0, "rest": 0.0}
    if stress is not None and stress > 25:
        parts["stress"] = min(STRESS_DRAIN, (stress - 25) / 75 * STRESS_DRAIN)
    if hr:
        # Effort starts at half the heart-rate reserve above rest.
        threshold = rest_hr + 0.5 * (hr_max - rest_hr)
        if hr > threshold:
            parts["activity"] = 2.0 + 2.0 * min(1.0, (hr - threshold) / max(1.0, hr_max - threshold))
    if steps:
        parts["activity"] += min(0.5, steps / 2000 * 0.5)
    if stress is not None and stress <= 25 and parts["activity"] == 0 and (steps or 0) < 50:
        parts["rest"] = REST_GAIN
    total = parts["awake"] + parts["stress"] + parts["activity"] - parts["rest"]
    return round(total, 3), parts


def _midnight(day: HealthDay) -> datetime:
    """The day's local midnight as UTC: a series start carries it exactly."""
    for name in ("heart_rate", "stress", "hrv", "steps", "temperature", "spo2"):
        series = getattr(day, name)
        if series and series.start:
            return parse_instant(series.start)
    return parse_instant(f"{day.date}T00:00:00Z") - timedelta(seconds=day.utc_offset)


def grid_floor(moment: datetime, midnight: datetime) -> datetime:
    """The slot boundary at or before `moment`, on the grid `midnight` sits on."""
    slots = math.floor((moment - midnight).total_seconds() / 60 / SLOT)
    return midnight + timedelta(minutes=slots * SLOT)


#: A night that began more than this before midnight is not tonight's.
EVENING = timedelta(hours=12)


def _slot_value(series: Optional[Series], start: datetime, end: datetime, total: bool = False) -> Optional[float]:
    if series is None or not series.start or not series.values:
        return None
    origin = parse_instant(series.start)
    interval = max(1, series.interval_minutes)
    picked = [float(v) for i, v in enumerate(series.values)
              if v and v > 0 and start <= origin + timedelta(minutes=i * interval) < end]
    if not picked:
        return None
    return sum(picked) if total else sum(picked) / len(picked)


@dataclass
class BatteryDay:
    date: str
    start_level: float
    bed_at: Optional[str] = None
    wake_at: Optional[str] = None
    wake_level: Optional[float] = None
    level: float = FIRST_LEVEL
    end_level: float = FIRST_LEVEL
    charged: float = 0.0
    naps: float = 0.0
    drained: float = 0.0
    drains: dict = field(default_factory=lambda: {"awake": 0.0, "stress": 0.0, "activity": 0.0, "rest": 0.0})
    curve: list = field(default_factory=list)
    biggest_drain: Optional[dict] = None
    calibrating: Optional[dict] = None
    partial: bool = False
    no_sleep: bool = False
    sleep_performance: Optional[float] = None
    recovery_factor: Optional[float] = None

    def to_json(self) -> dict:
        out = {name: getattr(self, name) for name in self.__dataclass_fields__}
        out["band"] = band(self.level)
        return out


def day_battery(day: HealthDay, start_level: float, baseline: Baseline, prior_nights: list[int],
                profile: dict, now: Optional[str] = None, bedtime: Optional[str] = None) -> BatteryDay:
    """The day's level every 30 minutes from local midnight to midnight, or to `now`.

    A night belongs to the day it ends on, all of it: one that began before
    midnight opens this day's curve at bedtime and charges in full, and
    `bedtime` — when tomorrow's night began — closes this day there, so
    those hours are neither drained here nor lost from tomorrow's charge.
    """
    midnight = _midnight(day)
    stop = midnight + timedelta(days=1)
    if bedtime:
        stop = min(stop, max(midnight, grid_floor(parse_instant(bedtime), midnight)))
    if now:
        stop = min(stop, parse_instant(now))
    rest = resting_hr(day) or baseline.resting_hr or 60.0
    hr_max = 220.0 - float((profile or {}).get("age") or 30)

    charge = overnight_charge(day, baseline, prior_nights)
    night = None if charge.no_sleep else day.main_sleep
    night_start = parse_instant(night.start) if night else None
    wake = parse_instant(night.end) if night else None
    naps = [s for s in day.sleep if s is not night and s.end and s.asleep_minutes < MAIN_SLEEP]

    begin = midnight
    if night is not None and midnight - EVENING < night_start < midnight:
        begin = grid_floor(night_start, midnight)
    # The charge is shared across the slots actually spent in bed, so the
    # whole night lands however the grid cuts it.
    bed_slots, slot = 0, begin
    while night is not None and slot < wake:
        bed_slots += night_start <= slot
        slot += timedelta(minutes=SLOT)

    out = BatteryDay(date=day.date, start_level=start_level, no_sleep=charge.no_sleep,
                     bed_at=night.start if night else None,
                     sleep_performance=charge.performance if night else None,
                     recovery_factor=charge.factor if night else None)
    if charge.calibrating:
        out.calibrating = {"nights": baseline.hrv_nights, "needed": CALIBRATION_NIGHTS}
    level = max(FLOOR, min(CEIL, float(start_level)))
    worst_cost, worst_at = 0.0, None
    awake_slots = blank_slots = 0
    cursor = begin
    while cursor < stop:
        slot_end = cursor + timedelta(minutes=SLOT)
        if night is not None and night_start <= cursor < wake:
            # The night's charge arrives evenly across the time in bed.
            gain = charge.points / max(1, bed_slots)
            level = min(CEIL, level + gain)
            out.charged += gain
        else:
            stress = _slot_value(day.stress, cursor, slot_end)
            hr = _slot_value(day.heart_rate, cursor, slot_end)
            steps = _slot_value(day.steps, cursor, slot_end, total=True)
            cost, parts = slot_drain(stress, hr, steps, rest, hr_max)
            awake_slots += 1
            if stress is None and hr is None and steps is None:
                blank_slots += 1
            for nap in naps:
                if cursor <= parse_instant(nap.end) < slot_end:
                    gain = MAX_CHARGE * min(1.0, nap.asleep_minutes / SLEEP_NEED) * NAP_RATE
                    out.naps += gain
                    cost -= gain
            level = max(FLOOR, min(CEIL, level - cost))
            out.drained += max(0.0, cost)
            for name, value in parts.items():
                out.drains[name] = out.drains.get(name, 0.0) + value
            if cost > worst_cost:
                worst_cost, worst_at = cost, cursor
        if wake is not None and out.wake_level is None and slot_end >= wake:
            out.wake_at, out.wake_level = _iso(wake), round(level, 1)
        cursor = slot_end
        out.curve.append({"at": _iso(cursor), "level": round(level, 1)})
    # A few unmeasured slots are ordinary (the ring samples every 30 minutes);
    # "partial" means the day was mostly guessed.
    out.partial = awake_slots > 0 and blank_slots / awake_slots > PARTIAL_SHARE
    out.level = out.end_level = round(level, 1)
    out.charged, out.drained, out.naps = round(out.charged, 1), round(out.drained, 1), round(out.naps, 1)
    out.drains = {k: round(v, 1) for k, v in out.drains.items()}
    if worst_at is not None:
        out.biggest_drain = {"start": _iso(worst_at), "end": _iso(worst_at + timedelta(minutes=SLOT)),
                             "points": round(worst_cost, 1)}
    return out
