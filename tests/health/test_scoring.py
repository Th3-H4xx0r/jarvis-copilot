"""Scores are ramps over stated targets, and say what they took off for."""
from jarvis_health.metrics import Baseline
from jarvis_health.scoring import (
    Score,
    activity_score,
    band,
    body_score,
    health_score,
    ramp,
    recovery_score,
    sleep_score,
)

from .fixtures import day, ready_baseline


def earned(score, name):
    return next(c.earned for c in score.points if c.name == name)


def test_ramp_is_full_inside_the_target_and_zero_outside_the_bounds():
    assert ramp(8, 7, 9, 3, 12, points=30) == 30
    assert ramp(3, 7, 9, 3, 12, points=30) == 0
    assert ramp(12, 7, 9, 3, 12, points=30) == 0
    assert 0 < ramp(5, 7, 9, 3, 12, points=30) < 30


def test_duration_is_full_between_seven_and_nine_hours():
    assert earned(sleep_score(day(asleep=480), ready_baseline()), "Duration") == 30
    assert earned(sleep_score(day(asleep=389), ready_baseline()), "Duration") < 30
    assert earned(sleep_score(day(asleep=150), ready_baseline()), "Duration") == 0


def test_a_broken_night_loses_restfulness_but_keeps_its_duration():
    calm = sleep_score(day(asleep=480, awake=5, awakenings=1), ready_baseline())
    broken = sleep_score(day(asleep=480, awake=70, awakenings=7), ready_baseline())
    assert earned(broken, "Restfulness") == 0
    assert earned(broken, "Duration") == earned(calm, "Duration") == 30
    assert broken.value < calm.value


def test_a_late_bedtime_loses_only_the_timing_points():
    on_time = sleep_score(day(bedtime_minute=1410), ready_baseline(bedtime_minute=1410))
    late = sleep_score(day(bedtime_minute=180), ready_baseline(bedtime_minute=1410))
    assert earned(on_time, "Timing") == 10
    assert earned(late, "Timing") == 0
    assert on_time.value - late.value == 10


def test_sleep_with_no_night_recorded_has_no_value_at_all():
    assert sleep_score(day(asleep=0), ready_baseline()).value is None


def test_recovery_waits_for_a_baseline_it_can_trust():
    assert recovery_score(day(), Baseline(hrv=45, resting_hr=58, days_used=2, hrv_days=2)).value is None
    # Days stored without HRV or a resting rate are not a baseline either.
    assert recovery_score(day(), Baseline(days_used=14)).value is None
    assert recovery_score(day(), ready_baseline()).value is not None


def test_recovery_needs_a_physiological_reading_not_just_last_nights_sleep():
    # Sleep already carries 0.35 of the health score; recovery must not become a
    # second copy of it when the ring recorded no HRV and no resting rate.
    blind = day(hrv=0, hr=[0] * 100)
    assert recovery_score(blind, ready_baseline()).value is None


def test_recovery_rewards_hrv_above_your_own_baseline():
    strong = recovery_score(day(hrv=52), ready_baseline(hrv=45))
    weak = recovery_score(day(hrv=27), ready_baseline(hrv=45))
    assert earned(strong, "HRV") == 50
    assert earned(weak, "HRV") == 0
    assert strong.value > weak.value


def test_body_reads_stress_bands_spo2_and_temperature():
    calm = body_score(day(stress=[30] * 48, spo2=98, temperature=36.5), ready_baseline())
    strained = body_score(day(stress=[85] * 48, spo2=88, temperature=38.2), ready_baseline())
    assert calm.value > strained.value
    assert earned(strained, "SpO₂") == 0


def test_activity_measures_against_the_goals_it_is_given():
    assert activity_score(day(steps=10000, active_minutes=30), {"steps": 10000, "active_minutes": 30}).value == 100
    assert activity_score(day(steps=0, active_minutes=0), {"steps": 10000, "active_minutes": 30}).value == 0


def test_health_weights_the_four_parts_and_renormalises_over_what_is_present():
    full = health_score({"sleep": Score(80), "recovery": Score(80), "body": Score(80), "activity": Score(80)})
    assert round(full.value) == 80

    partial = health_score(
        {"sleep": Score(80), "recovery": Score(None), "body": Score(60), "activity": Score(40)}
    )
    assert round(partial.value) == 68
    assert "recovery" in partial.missing


def test_health_has_no_value_when_nothing_could_be_scored():
    assert health_score({"sleep": Score(None), "recovery": Score(None)}).value is None


def test_bands_name_the_score():
    assert band(86) == "Excellent"
    assert band(72) == "Good"
    assert band(60) == "Fair"
    assert band(40) == "Low"
    assert band(None) == "—"


def test_a_reading_off_the_scale_leaves_the_stress_denominator():
    from jarvis_health.scoring import stress_band_shares

    # The ring's samples are raw bytes; a garbled 255 is not a relaxed minute.
    shares = stress_band_shares([20] * 24 + [255] * 24)
    assert round(sum(shares.values())) == 100
    assert shares["Relax"] == 100


def test_the_band_agrees_with_the_number_beside_it():
    assert Score(84.6).to_json()["value"] == 85
    assert Score(84.6).to_json()["band"] == "Excellent"
    assert Score(54.7).to_json()["band"] == "Fair"
    assert Score(69.8).to_json()["band"] == "Good"
