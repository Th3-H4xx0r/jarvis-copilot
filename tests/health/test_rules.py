"""Alerts are thresholds, evaluated the same way every time."""
from jarvis_health.metrics import Baseline
from jarvis_health.rules import DEFAULT_RULES, evaluate, in_quiet_hours
from jarvis_health.scoring import Score

from .fixtures import day, ready_baseline

SETTINGS = {"rules": DEFAULT_RULES, "quiet_hours": {"start": "22:00", "end": "08:00"}}


def scores(health=80, sleep=80):
    return {"health": Score(health), "sleep": Score(sleep)}


def fired(alerts):
    return {a.rule for a in alerts}


def noon():
    return "2026-09-17T17:00:00Z"  # 12:00 in America/Chicago


def test_resting_hr_fires_at_its_threshold_and_not_below():
    hot = day(hr=[0] * 12 + [65] * 40 + [70] * 60)
    cool = day(hr=[0] * 12 + [64] * 40 + [70] * 60)
    base = ready_baseline(resting_hr=58)
    assert "resting_hr_high" in fired(evaluate(hot, scores(), base, SETTINGS, noon(), set()))
    assert "resting_hr_high" not in fired(evaluate(cool, scores(), base, SETTINGS, noon(), set()))


def test_low_hrv_short_sleep_low_spo2_and_a_low_score_each_fire():
    d = day(hrv=30, asleep=240, spo2=88)
    alerts = fired(evaluate(d, scores(health=20), ready_baseline(hrv=45), SETTINGS, noon(), set()))
    assert {"hrv_low", "short_sleep", "spo2_low", "health_low"} <= alerts


def test_sustained_high_stress_fires_but_a_single_spike_does_not():
    sustained = day(stress=[30] * 20 + [70] * 4 + [30] * 24)  # 30-min samples: two hours high
    spike = day(stress=[30] * 20 + [70] + [30] * 27)
    assert "stress_sustained" in fired(evaluate(sustained, scores(), ready_baseline(), SETTINGS, noon(), set()))
    assert "stress_sustained" not in fired(evaluate(spike, scores(), ready_baseline(), SETTINGS, noon(), set()))


def test_a_low_ring_battery_fires():
    d = day()
    d.battery = {"percent": 12, "charging": False}
    assert "battery_low" in fired(evaluate(d, scores(), ready_baseline(), SETTINGS, noon(), set()))


def test_a_disabled_rule_never_fires():
    settings = {**SETTINGS, "rules": {**DEFAULT_RULES, "short_sleep": {"enabled": False, "threshold": 5}}}
    assert "short_sleep" not in fired(evaluate(day(asleep=120), scores(), ready_baseline(), settings, noon(), set()))


def test_no_rule_fires_twice_in_a_day():
    d = day(asleep=120)
    assert evaluate(d, scores(), ready_baseline(), SETTINGS, noon(), {"short_sleep", "health_low"}) == []


def test_stale_data_fires_nothing():
    assert evaluate(day(asleep=120), scores(), ready_baseline(), SETTINGS, noon(), set(), stale=True) == []


def test_quiet_hours_hold_an_alert_until_morning():
    night = "2026-09-17T07:00:00Z"  # 02:00 local
    assert in_quiet_hours(night, SETTINGS) is True
    held = evaluate(day(asleep=120), scores(), ready_baseline(), SETTINGS, night, set())
    assert held and all(a.hold_until == "08:00" for a in held)


def test_an_alert_outside_quiet_hours_goes_out_immediately():
    alerts = evaluate(day(asleep=120), scores(), ready_baseline(), SETTINGS, noon(), set())
    assert alerts and all(a.hold_until is None for a in alerts)


def test_sustained_stress_means_consecutive_readings_not_a_count_of_spikes():
    from jarvis_health.rules import sustained_high_stress

    spikes = [20] * 48
    spikes[10] = 65
    spikes[40] = 61          # two lone 30-minute samples, fifteen hours apart
    assert sustained_high_stress(day(stress=spikes)) == 30
    assert "stress_sustained" not in fired(evaluate(day(stress=spikes), scores(), ready_baseline(), SETTINGS, noon(), set()))

    run = [20] * 48
    run[20:24] = [70] * 4    # two unbroken hours while awake
    assert sustained_high_stress(day(stress=run)) == 120
    assert "stress_sustained" in fired(evaluate(day(stress=run), scores(), ready_baseline(), SETTINGS, noon(), set()))


def test_high_stress_while_asleep_is_not_an_alert():
    asleep = [20] * 48
    asleep[4:12] = [70] * 8  # 02:00-05:30, inside the night the fixture records
    assert "stress_sustained" not in fired(
        evaluate(day(stress=asleep), scores(), ready_baseline(), SETTINGS, noon(), set()))


def test_a_day_with_no_real_sleep_does_not_get_a_zero_hour_sleep_alert():
    from jarvis_health.metrics import STAGE_AWAKE, HealthDay, SleepSession

    charging = HealthDay(
        date="2026-09-17", timezone="America/Chicago", utc_offset=-18000,
        sleep=[SleepSession(start="2026-09-17T09:00:00Z", end="2026-09-17T09:25:00Z",
                            stages=[(STAGE_AWAKE, 25)])],
    )
    assert "short_sleep" not in fired(
        evaluate(charging, scores(), ready_baseline(), SETTINGS, noon(), set()))
