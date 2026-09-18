"""Body Battery: charged by sleep, drained by the waking day, judged against you."""
import pytest

from jarvis_health.battery import band, day_battery, overnight_charge, recovery_factor, slot_drain, sleep_need

from .fixtures import day, ready_baseline


def _ready():
    base = ready_baseline()
    base.ln_hrv_mean, base.ln_hrv_sd, base.hrv_nights = 3.8067, 0.1, 7   # about 45 ms
    return base


def test_bands_follow_garmin():
    assert [band(v) for v in (90, 60, 30, 10)] == ["High", "Medium", "Low", "Very low"]


def test_a_full_good_night_charges_55_to_65():
    assert 55 <= overnight_charge(day(asleep=480, hrv=45), _ready(), [480] * 3).points <= 65


def test_five_hours_with_suppressed_hrv_charges_about_25():
    tired = day(asleep=300, hrv=35, hr=[0] * 60 + [66] * 12 + [70] * 100)
    assert 18 <= overnight_charge(tired, _ready(), [480] * 3).points <= 32


def test_no_sleep_means_no_charge():
    charge = overnight_charge(day(asleep=0), _ready(), [])
    assert charge.points == 0 and charge.no_sleep


def test_calibrating_caps_the_charge_at_50():
    base = _ready()
    base.hrv_nights = 3
    charge = overnight_charge(day(asleep=540), base, [])
    assert charge.points <= 50 and charge.calibrating


def test_sleep_debt_raises_the_need():
    assert (sleep_need(0), sleep_need(120), sleep_need(600)) == (480, 540, 600)


def test_noise_inside_the_band_does_not_move_recovery():
    assert recovery_factor(46, 58, _ready()) == 1.0


def test_a_raised_resting_heart_rate_costs_recovery():
    assert recovery_factor(45, 66, _ready()) < 0.9


def test_a_typical_day_drains_45_to_65():
    d = day(asleep=480, stress=[0] * 16 + [45] * 32, steps=8000)
    assert 45 <= day_battery(d, 40, _ready(), [480] * 3, {"age": 30}).drained <= 65


def test_ring_off_drains_only_the_baseline():
    assert slot_drain(None, None, None, rest_hr=58, hr_max=190) == (1.0, {"awake": 1.0})


def test_a_hard_effort_drains_more_than_sitting():
    sitting, _ = slot_drain(40, 70, 100, rest_hr=58, hr_max=190)
    running, parts = slot_drain(40, 165, 2500, rest_hr=58, hr_max=190)
    assert running > sitting + 2 and parts["activity"] > 2


def test_the_battery_charges_through_the_night_and_falls_through_the_day():
    battery = day_battery(day(asleep=480), 30, _ready(), [480] * 3, {}).to_json()
    assert battery["wake_level"] > 80
    assert battery["level"] < battery["wake_level"]
    assert battery["band"] == band(battery["level"])


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
    charge = overnight_charge(d, _ready(), [480] * 3)
    battery = day_battery(d, 30, _ready(), [480] * 3, {})
    assert battery.charged == pytest.approx(charge.points, abs=0.1)
    assert battery.curve[0]["at"] == "2026-09-17T03:30:00Z", "the day's curve opens at bedtime"
    assert battery.bed_at == d.main_sleep.start


def test_a_day_closes_at_bedtime_when_the_next_night_began_before_midnight():
    battery = day_battery(day(asleep=480), 30, _ready(), [480] * 3, {}, bedtime="2026-09-18T03:10:00Z")
    assert battery.curve[-1]["at"] == "2026-09-18T03:00:00Z", "22:10 in bed: the day ends on the 22:00 slot"
    assert battery.end_level == battery.curve[-1]["level"]
