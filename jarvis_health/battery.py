"""Body Battery: a reservoir sleep fills and the waking day drains.

The core is the two-process model of sleep regulation (Borbély; Daan, Beersma
& Borbély 1984), the clinical account of why energy falls through a long day:
sleep pressure, Process S, builds while awake toward its ceiling with a time
constant of 18.2 h and dissipates while asleep with one of 4.2 h. The battery
is 100 × (1 − S), so a short night can't refill it, a long day empties it
even when calm, and an empty battery recovers more per hour than a full one —
the shape of SAFTE's sleep reservoir (Hursh) too.

On top, Garmin/Firstbeat's drains: stress (Firstbeat's 0–100 bands: rest
0–25, low 26–50, medium 51–75, high 76–100) and physical effort by heart-rate
reserve cost extra points; only sleep charges. Each night's recovery is
judged the way WHOOP judges it: HRV and resting heart rate against your own
baseline speed or slow the overnight dissipation. Pure functions over stored
days; the runner stores each day's curve, so tomorrow starts from tonight's
real level.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

from .baselines import resting_hr, sleeping_hrv
from .metrics import Baseline, HealthDay, Series, SleepSession, _iso, parse_instant

FLOOR, CEIL, FIRST_LEVEL = 5.0, 100.0, 50.0
#: Process S time constants, hours: build-up awake, dissipation asleep.
TAU_WAKE, TAU_SLEEP = 18.2, 4.2
#: Until a week of nights has built the HRV baseline, recovery cannot be
#: judged, so a night is never counted better than average.
CALIBRATION_NIGHTS = 7
SLEEP_NEED = 480.0
#: Asleep at least this long is a night; less is a nap.
MAIN_SLEEP = 180
SLOT = 30
#: The smallest worthwhile change in log-HRV, in SDs (Plews/Buchheit).
SWC = 0.5

#: Extra points an hour at the top of each scale.
STRESS_DRAIN_H = 4.0
ACTIVITY_DRAIN_H = 20.0
#: Stress above this costs (Firstbeat's rest band ends at 25).
STRESS_REST = 25
#: Effort starts at this share of the heart-rate reserve and peaks at this.
EFFORT_FROM, EFFORT_PEAK = 0.3, 0.9
#: Steps in a half hour that count as a brisk walk, when the heart rate is missing.
BRISK_STEPS = 3000
WALK_DRAIN_H = 3.0

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


def pressure(level: float) -> float:
    """Process S for a battery level: 0 rested, 1 spent."""
    return 1.0 - max(FLOOR, min(CEIL, level)) / CEIL


def level_of(s: float) -> float:
    return max(FLOOR, min(CEIL, CEIL * (1.0 - s)))


def awake_pressure(s: float, minutes: float) -> float:
    """S after `minutes` awake: it climbs toward 1, slower the higher it is."""
    return 1.0 - (1.0 - s) * math.exp(-minutes / 60.0 / TAU_WAKE)


def asleep_pressure(s: float, minutes: float, factor: float = 1.0) -> float:
    """S after `minutes` asleep; a better-recovered night (factor > 1) clears it faster."""
    return s * math.exp(-minutes / 60.0 / (TAU_SLEEP / max(0.1, factor)))


@dataclass
class Charge:
    performance: float = 0.0
    factor: float = 1.0
    need: float = SLEEP_NEED
    calibrating: bool = False
    no_sleep: bool = False


def overnight_recovery(day: HealthDay, baseline: Baseline, prior_nights: list[int]) -> Charge:
    """How last night recovered: how much of the need it slept, and how well (HRV, resting HR)."""
    calibrating = baseline.hrv_nights < CALIBRATION_NIGHTS
    night = day.main_sleep
    if night is None or night.asleep_minutes < MAIN_SLEEP:
        return Charge(calibrating=calibrating, no_sleep=True)
    need = sleep_need(sleep_debt(prior_nights))
    performance = min(1.0, night.asleep_minutes / need)
    factor = recovery_factor(sleeping_hrv(day), resting_hr(day), baseline)
    if calibrating:
        factor = min(1.0, factor)
    return Charge(round(performance, 3), factor, need, calibrating)


def effort(hr: float, rest_hr: float, hr_max: float) -> float:
    """0–1: how hard a heart rate is working, by heart-rate reserve (Karvonen)."""
    reserve = (hr - rest_hr) / max(1.0, hr_max - rest_hr)
    return max(0.0, min(1.0, (reserve - EFFORT_FROM) / (EFFORT_PEAK - EFFORT_FROM))) ** 2


def slot_drain(stress: Optional[float], efforts: list[float], steps: Optional[float]) -> tuple[float, dict]:
    """Points a 30-minute awake slot costs on top of being awake, and what took them.

    `efforts` are `effort()` of the heart rates in the slot: the hard minutes
    count however few, where a mean heart rate would dilute them.
    """
    hours = SLOT / 60.0
    parts = {"stress": 0.0, "activity": 0.0}
    if stress is not None and stress > STRESS_REST:
        parts["stress"] = STRESS_DRAIN_H * min(1.0, (stress - STRESS_REST) / (100.0 - STRESS_REST)) * hours
    hard = ACTIVITY_DRAIN_H * (sum(efforts) / len(efforts)) * hours if efforts else 0.0
    walk = WALK_DRAIN_H * min(1.0, (steps or 0.0) / BRISK_STEPS) * hours
    parts["activity"] = max(hard, walk)
    return round(sum(parts.values()), 3), parts


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


def _slot_values(series: Optional[Series], start: datetime, end: datetime) -> list[float]:
    if series is None or not series.start or not series.values:
        return []
    origin = parse_instant(series.start)
    interval = max(1, series.interval_minutes)
    return [float(v) for i, v in enumerate(series.values)
            if v and v > 0 and start <= origin + timedelta(minutes=i * interval) < end]


def _slot_value(series: Optional[Series], start: datetime, end: datetime, total: bool = False) -> Optional[float]:
    picked = _slot_values(series, start, end)
    if not picked:
        return None
    return sum(picked) if total else sum(picked) / len(picked)


def _overlap(a0: datetime, a1: datetime, b0: datetime, b1: datetime) -> float:
    """Minutes the two spans share."""
    return max(0.0, (min(a1, b1) - max(a0, b0)).total_seconds() / 60.0)


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
    drains: dict = field(default_factory=lambda: {"awake": 0.0, "stress": 0.0, "activity": 0.0})
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


def _workout_samples(workouts: Optional[list[dict]], start: datetime, end: datetime) -> list[float]:
    """Heart rates a workout recorded inside the slot (its samples are 5 s apart)."""
    readings = []
    for w in workouts or []:
        if not w.get("start"):
            continue
        origin = parse_instant(w["start"])
        for i, bpm in enumerate(w.get("heart_rates") or []):
            if bpm and start <= origin + timedelta(seconds=5 * i) < end:
                readings.append(float(bpm))
    return readings


def day_battery(day: HealthDay, start_level: float, baseline: Baseline, prior_nights: list[int],
                profile: dict, now: Optional[str] = None, bedtime: Optional[str] = None,
                workouts: Optional[list[dict]] = None) -> BatteryDay:
    """The day's level every 30 minutes from local midnight to midnight, or to `now`.

    A night belongs to the day it ends on, all of it: one that began before
    midnight opens this day's curve at bedtime, and `bedtime` — when
    tomorrow's night began — closes this day there, so those hours are
    neither drained here nor lost from tomorrow's charge.
    """
    midnight = _midnight(day)
    stop = midnight + timedelta(days=1)
    if bedtime:
        stop = min(stop, max(midnight, grid_floor(parse_instant(bedtime), midnight)))
    if now:
        stop = min(stop, parse_instant(now))
    rest = resting_hr(day) or baseline.resting_hr or 60.0
    hr_max = 220.0 - float((profile or {}).get("age") or 30)

    recovery = overnight_recovery(day, baseline, prior_nights)
    night = None if recovery.no_sleep else day.main_sleep
    night_start = parse_instant(night.start) if night else None
    wake = parse_instant(night.end) if night else None
    # Every sleep the day holds, with how fast it clears pressure: the night by
    # its recovery, a nap at the ordinary rate.
    sessions: list[tuple[SleepSession, datetime, datetime, float]] = []
    for s in day.sleep:
        if not s.start or not s.end or (s is not night and s.asleep_minutes >= MAIN_SLEEP):
            continue
        sessions.append((s, parse_instant(s.start), parse_instant(s.end), recovery.factor if s is night else 1.0))

    begin = midnight
    if night is not None and midnight - EVENING < night_start < midnight:
        begin = grid_floor(night_start, midnight)

    out = BatteryDay(date=day.date, start_level=start_level, no_sleep=recovery.no_sleep,
                     bed_at=night.start if night else None,
                     sleep_performance=recovery.performance if night else None,
                     recovery_factor=recovery.factor if night else None)
    if recovery.calibrating:
        out.calibrating = {"nights": baseline.hrv_nights, "needed": CALIBRATION_NIGHTS}
    level = max(FLOOR, min(CEIL, float(start_level)))
    worst_cost, worst_at = 0.0, None
    awake_slots = blank_slots = 0
    cursor = begin
    while cursor < stop:
        slot_end = cursor + timedelta(minutes=SLOT)
        in_bed, sleep_first, asleep = 0.0, False, []
        for s, s0, s1, factor in sessions:
            shared = _overlap(cursor, slot_end, s0, s1)
            if shared <= 0:
                continue
            in_bed += shared
            sleep_first = sleep_first or s0 <= cursor
            asleep.append((shared * (s.efficiency or 1.0), factor, s is night))
        awake = max(0.0, SLOT - in_bed)

        def sleep_part() -> None:
            nonlocal level
            for minutes, factor, is_night in asleep:
                before = level
                level = level_of(asleep_pressure(pressure(level), minutes, factor))
                if is_night:
                    out.charged += level - before
                else:
                    out.naps += level - before

        def awake_part() -> None:
            nonlocal level, worst_cost, worst_at, awake_slots, blank_slots
            if awake <= 0:
                return
            stress = _slot_value(day.stress, cursor, slot_end)
            heart = _slot_values(day.heart_rate, cursor, slot_end)
            # The ring's 5-minute history can miss a workout; its own
            # second-by-second heart rate says what the slot cost.
            during = _workout_samples(workouts, cursor, slot_end)
            steps = _slot_value(day.steps, cursor, slot_end, total=True)
            efforts = [effort(hr, rest, hr_max) for hr in heart]
            if during:
                covered = min(1.0, len(during) * 5 / 60 / SLOT)
                mean = lambda xs: sum(xs) / len(xs) if xs else 0.0
                efforts = [covered * mean([effort(hr, rest, hr_max) for hr in during])
                           + (1 - covered) * mean(efforts)]
            share = awake / SLOT
            extra, parts = slot_drain(stress, efforts, steps)
            spent = level - level_of(awake_pressure(pressure(level), awake))
            cost = spent + extra * share
            level = max(FLOOR, level - cost)
            out.drained += cost
            out.drains["awake"] += spent
            for name, value in parts.items():
                out.drains[name] += value * share
            if share >= 0.5:
                awake_slots += 1
                if stress is None and not heart and not during and steps is None:
                    blank_slots += 1
            if cost > worst_cost:
                worst_cost, worst_at = cost, cursor

        if sleep_first:
            sleep_part()
            awake_part()
        else:
            awake_part()
            sleep_part()
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
