"""Days built by hand, so a score's inputs are visible in the test that reads it."""
from datetime import timedelta

from jarvis_health.metrics import (
    STAGE_AWAKE,
    STAGE_DEEP,
    STAGE_LIGHT,
    STAGE_REM,
    Baseline,
    HealthDay,
    Series,
    SleepSession,
    local_midnight_utc,
    parse_instant,
)


def _iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")

TZ = "America/Chicago"


def series(values, interval=5, date="2026-09-17"):
    return Series(start=local_midnight_utc(date, TZ), interval_minutes=interval, values=list(values))


def night(asleep=480, deep=None, rem=None, awake=7, awakenings=1, bedtime_minute=1410):
    """A night of `asleep` minutes with healthy stage shares unless told otherwise."""
    deep = int(asleep * 0.18) if deep is None else deep
    rem = int(asleep * 0.22) if rem is None else rem
    light = max(0, asleep - deep - rem)
    stages = [(STAGE_DEEP, deep), (STAGE_LIGHT, light), (STAGE_REM, rem)]
    per_waking = awake // awakenings if awakenings else 0
    stages += [(STAGE_AWAKE, per_waking)] * awakenings
    # A bedtime after noon belongs to the previous local day; the stored instant is UTC.
    offset = bedtime_minute - 1440 if bedtime_minute > 720 else bedtime_minute
    start = parse_instant(local_midnight_utc("2026-09-17", TZ)) + timedelta(minutes=offset)
    end = start + timedelta(minutes=sum(m for _, m in stages))
    return SleepSession(start=_iso(start), end=_iso(end), stages=stages)


def day(
    date="2026-09-17",
    asleep=480,
    deep=None,
    rem=None,
    awake=7,
    awakenings=1,
    hrv=45,
    hr=None,
    stress=None,
    spo2=98,
    temperature=36.5,
    steps=8000,
    active_minutes=30,
    bedtime_minute=1410,
):
    hr_values = hr if hr is not None else [0] * 60 + [58] * 12 + [70] * 100
    stress_values = stress if stress is not None else [40] * 48
    return HealthDay(
        date=date,
        timezone=TZ,
        utc_offset=-18000,
        sleep=[night(asleep, deep, rem, awake, awakenings, bedtime_minute)] if asleep else [],
        heart_rate=series(hr_values),
        hrv=series([hrv] * 48 if hrv else [], interval=30),
        stress=series(stress_values, interval=30),
        spo2=series([spo2] * 24 if spo2 else [], interval=60),
        temperature=series([temperature] * 24 if temperature else [], interval=60),
        activity={"steps": steps, "active_minutes": active_minutes},
        battery={"percent": 60, "charging": False},
    )


def ready_baseline(hrv=45, resting_hr=58, bedtime_minute=1410, sleep_minutes=450, temperature=36.5):
    return Baseline(
        hrv=hrv,
        resting_hr=resting_hr,
        bedtime_minute=bedtime_minute,
        sleep_minutes=sleep_minutes,
        temperature=temperature,
        days_used=14,
        hrv_days=14,
        resting_hr_days=14,
    )
