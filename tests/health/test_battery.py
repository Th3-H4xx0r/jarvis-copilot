"""Body Battery: charged by sleep, drained by the waking day, judged against you."""
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
