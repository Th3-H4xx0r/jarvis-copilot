"""Sleep debt: a week of nights against the goal, built up night by night."""
from jarvis_health.sleep_debt import band, goal_of, slept, week
from jarvis_health.store import HealthStore

from .fixtures import day, night

KEY = "ring-aaaa0000"


def _week(store, asleep_by_date):
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    for date, asleep in asleep_by_date.items():
        store.put_day(day(date=date, asleep=asleep), KEY)


def test_the_bands_read_like_the_guidance():
    assert [band(m) for m in (0, 59, 60, 299, 300, 599, 600)] == \
        ["None", "None", "Low", "Low", "Medium", "Medium", "High"]


def test_short_nights_build_the_debt_and_a_long_one_pays_some_back(tmp_registry):
    store = HealthStore()
    _week(store, {"2026-09-15": 360, "2026-09-16": 420, "2026-09-17": 540})
    out = week(store, "2026-09-17", goal=480)
    debts = [n["debt"] for n in out["nights"][-3:]]
    assert debts == [120, 180, 120], "−2h, −1h, then +1h back"
    assert out["debt"] == 120 and out["band"] == "Low"
    assert out["short_nights"] == 2 and out["measured"] == 3
    assert out["average"] == 440


def test_it_never_goes_below_nothing(tmp_registry):
    store = HealthStore()
    _week(store, {"2026-09-16": 600, "2026-09-17": 300})
    assert [n["debt"] for n in week(store, "2026-09-17", goal=480)["nights"][-2:]] == [0, 180]


def test_an_unmeasured_night_is_not_a_sleepless_one(tmp_registry):
    store = HealthStore()
    _week(store, {"2026-09-17": 480})
    out = week(store, "2026-09-17")
    assert out["nights"][0]["asleep"] is None and out["nights"][0]["debt"] == 0
    assert out["measured"] == 1


def test_a_night_reported_three_times_as_it_grew_counts_once():
    d = day(asleep=400)
    grown = night(asleep=460)
    d.sleep = [d.sleep[0], grown]            # same bedtime, two lengths
    assert slept(d) == 460


def test_a_nap_adds_to_the_night():
    d = day(asleep=400)
    nap = night(asleep=40, bedtime_minute=840)   # 14:00
    d.sleep.append(nap)
    assert slept(d) == 440


def test_the_goal_comes_from_settings_and_defaults_to_eight_hours(tmp_registry):
    assert goal_of({"goals": {"sleep_minutes": 450}}) == 450
    assert goal_of(HealthStore().settings()) == 480
