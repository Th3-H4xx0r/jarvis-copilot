"""Body Battery: Process S (two-process model) filled by sleep, drained by the
waking day, with Firstbeat-style stress and effort drains on top."""
import math

import pytest

from jarvis_health.battery import (
    asleep_pressure, awake_pressure, band, day_battery, effort, level_of, overnight_recovery, pressure,
    recovery_factor, sleep_need, slot_drain,
)

from .fixtures import day, ready_baseline


def _ready():
    base = ready_baseline()
    base.ln_hrv_mean, base.ln_hrv_sd, base.hrv_nights = 3.8067, 0.1, 7   # about 45 ms
    return base


def test_bands_follow_garmin():
    assert [band(v) for v in (90, 60, 30, 10)] == ["High", "Medium", "Low", "Very low"]


def test_process_s_builds_awake_and_clears_asleep_with_the_published_time_constants():
    # 18.2 h awake: the distance to the ceiling shrinks by 1/e; 4.2 h asleep: pressure falls by 1/e.
    assert 1 - awake_pressure(0.2, 18.2 * 60) == pytest.approx(0.8 / math.e)
    assert asleep_pressure(0.6, 4.2 * 60) == pytest.approx(0.6 / math.e)
    assert level_of(pressure(73.0)) == pytest.approx(73.0)


def test_a_long_calm_day_empties_the_battery():
    """His complaint: awake since 7 AM, still ~60 at midnight. 17 calm hours from 85 end near 35."""
    after = level_of(awake_pressure(pressure(85), 17 * 60))
    assert 30 <= after <= 40


def test_a_short_night_cannot_refill_it_and_a_full_one_nearly_does():
    six = level_of(asleep_pressure(pressure(30), 6.4 * 60))
    eight = level_of(asleep_pressure(pressure(30), 8 * 60))
    assert 80 <= six <= 88
    assert 88 <= eight <= 93
    assert six < eight < 100


def test_a_well_recovered_night_charges_more_than_a_strained_one():
    good = level_of(asleep_pressure(pressure(30), 420, 1.15))
    poor = level_of(asleep_pressure(pressure(30), 420, 0.6))
    assert good > poor + 15


def test_no_sleep_means_no_recovery():
    assert overnight_recovery(day(asleep=0), _ready(), []).no_sleep


def test_calibrating_never_counts_a_night_better_than_average():
    base = _ready()
    base.hrv_nights = 3
    recovery = overnight_recovery(day(asleep=540, hrv=70), base, [])
    assert recovery.factor <= 1.0 and recovery.calibrating


def test_sleep_debt_raises_the_need():
    assert (sleep_need(0), sleep_need(120), sleep_need(600)) == (480, 540, 600)


def test_noise_inside_the_band_does_not_move_recovery():
    assert recovery_factor(46, 58, _ready()) == 1.0


def test_a_raised_resting_heart_rate_costs_recovery():
    assert recovery_factor(45, 66, _ready()) < 0.9


def test_stress_drains_by_firstbeats_bands():
    assert slot_drain(20, [], None) == (0.0, {"stress": 0.0, "activity": 0.0}), "rest band: nothing extra"
    low, _ = slot_drain(45, [], None)
    high, _ = slot_drain(90, [], None)
    assert 0 < low < high <= 2.0


def test_a_hard_effort_drains_far_more_than_sitting():
    sitting = [effort(70, 58, 190)]
    running = [effort(165, 58, 190)]
    assert sitting == [0.0]
    cost, parts = slot_drain(40, running, 2500)
    assert parts["activity"] > 5, "a half hour at ~80% of heart-rate reserve"
    assert cost > slot_drain(40, sitting, 100)[0] + 5


def test_a_few_hard_minutes_count_even_when_the_mean_heart_rate_is_easy():
    hard = [effort(hr, 58, 190) for hr in [180] * 10 + [70] * 20]
    mean = [effort(sum([180] * 10 + [70] * 20) / 30, 58, 190)]
    assert slot_drain(None, hard, None)[0] > slot_drain(None, mean, None)[0]


def test_a_typical_day_charges_and_then_drains_50_to_70():
    d = day(asleep=420, stress=[0] * 16 + [45] * 32, steps=8000)
    battery = day_battery(d, 30, _ready(), [480] * 3, {"age": 22})
    assert 80 <= battery.wake_level <= 92
    assert 50 <= battery.drained <= 70
    assert 15 <= battery.level <= 35


def test_the_battery_charges_through_the_night_and_falls_through_the_day():
    battery = day_battery(day(asleep=480), 30, _ready(), [480] * 3, {}).to_json()
    assert battery["wake_level"] > 80
    assert battery["level"] < battery["wake_level"]
    assert battery["band"] == band(battery["level"])


def test_awake_in_bed_does_not_charge():
    restless = day(asleep=300, awake=180, awakenings=6)
    calm = day(asleep=480)
    assert day_battery(restless, 30, _ready(), [480] * 3, {}).charged < \
        day_battery(calm, 30, _ready(), [480] * 3, {}).charged - 5


def test_levels_stay_between_5_and_100():
    d = day(asleep=600, stress=[0] * 16 + [95] * 32)
    curve = day_battery(d, 95, _ready(), [600] * 3, {}).to_json()["curve"]
    assert all(5 <= p["level"] <= 100 for p in curve)


def test_a_few_unmeasured_slots_are_not_partial_data():
    d = day(asleep=480)
    # Heart rate stops at 14:20 in the fixture; blank stress for 14:30–15:30
    # too, and those two slots have nothing at all.
    d.stress.values[29] = 0
    d.stress.values[30] = 0
    assert day_battery(d, 40, _ready(), [480] * 3, {}).partial is False


def test_a_mostly_unmeasured_day_is_partial():
    d = day(asleep=480, stress=[0] * 48, hr=[0] * 288)
    assert day_battery(d, 40, _ready(), [480] * 3, {}).partial is True


def test_a_night_that_starts_before_midnight_charges_in_full():
    # In bed at 22:00: two hours of the night fall on the day before, and
    # they charge today's battery rather than draining yesterday's.
    d = day(asleep=480, bedtime_minute=1320)
    battery = day_battery(d, 30, _ready(), [480] * 3, {})
    assert battery.wake_level > 85, "the whole night charged, its pre-midnight hours too"
    assert battery.curve[0]["at"] == "2026-09-17T03:30:00Z", "the day's curve opens at bedtime"
    assert battery.bed_at == d.main_sleep.start


def test_a_day_closes_at_bedtime_when_the_next_night_began_before_midnight():
    battery = day_battery(day(asleep=480), 30, _ready(), [480] * 3, {}, bedtime="2026-09-18T03:10:00Z")
    assert battery.curve[-1]["at"] == "2026-09-18T03:00:00Z", "22:10 in bed: the day ends on the 22:00 slot"
    assert battery.end_level == battery.curve[-1]["level"]


def test_a_workout_the_ring_history_missed_still_drains():
    d = day(asleep=480, hr=[0] * 288, stress=[20] * 48)          # a calm, unmeasured-heart day
    calm = day_battery(d, 60, _ready(), [480] * 3, {"age": 30})
    run = {"start": "2026-09-17T22:00:00Z", "heart_rates": [165] * 360}   # 30 min at 165
    hard = day_battery(d, 60, _ready(), [480] * 3, {"age": 30}, workouts=[run])
    assert hard.drained > calm.drained + 1.5
