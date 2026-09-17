"""The vocabulary every health source fills in and every score reads."""
from jarvis_health.metrics import (
    STAGE_AWAKE,
    STAGE_DEEP,
    STAGE_LIGHT,
    STAGE_REM,
    Baseline,
    HealthDay,
    Series,
    SleepSession,
    from_json,
    local_midnight_utc,
    to_json,
)


def test_series_maps_index_to_utc_instant():
    s = Series(start="2026-09-17T05:00:00Z", interval_minutes=5, values=[0, 70, 72])
    assert s.at(0) == "2026-09-17T05:00:00Z"
    assert s.at(2) == "2026-09-17T05:10:00Z"
    assert s.nonzero() == [70, 72]


def test_sleep_session_counts_stages_and_awakenings():
    night = SleepSession(
        start="2026-09-17T05:23:00Z",
        end="2026-09-17T11:59:00Z",
        stages=[(STAGE_DEEP, 68), (STAGE_LIGHT, 273), (STAGE_REM, 48), (STAGE_AWAKE, 7)],
    )
    assert night.asleep_minutes == 389
    assert night.time_in_bed_minutes == 396
    assert night.awakenings == 1
    assert night.stage_minutes(STAGE_DEEP) == 68
    assert round(night.efficiency, 3) == round(389 / 396, 3)


def test_day_round_trips_through_json_keeping_zone_and_series():
    day = HealthDay(
        date="2026-09-17",
        timezone="America/Chicago",
        utc_offset=-18000,
        heart_rate=Series(start="2026-09-17T05:00:00Z", interval_minutes=5, values=[0, 70]),
        activity={"steps": 4200},
    )
    back = from_json(to_json(day))
    assert back.utc_offset == -18000
    assert back.timezone == "America/Chicago"
    assert back.heart_rate.values == [0, 70]
    assert back.activity["steps"] == 4200


def test_has_reports_which_metrics_this_source_filled_in():
    day = HealthDay(date="2026-09-17", timezone="UTC", utc_offset=0, activity={"steps": 10})
    assert day.has("activity") is True
    assert day.has("sleep") is False
    assert day.has("hrv") is False


def test_local_midnight_is_expressed_in_utc_for_the_stored_zone():
    assert local_midnight_utc("2026-09-17", "America/Chicago") == "2026-09-17T05:00:00Z"
    assert local_midnight_utc("2026-01-17", "America/Chicago") == "2026-01-17T06:00:00Z"


def test_a_baseline_knows_how_thin_it_is():
    assert Baseline(days_used=2).is_ready is False
    assert Baseline(hrv=45, resting_hr=58, days_used=4).is_ready is True
