"""History: every metric over a week, a month, six months or a year."""
from jarvis_health.history import day_summary, history
from jarvis_health.store import HealthStore
from jarvis_health.window import cycle

from .fixtures import day, series

KEY = "ring-aaaa0000"
NOW = "2026-09-18T20:00:00Z"


def _stored(store, **by_date):
    """Days keyed `d2026_09_17=dict(...)` → a stored ring day with a steps series."""
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    for key, kw in by_date.items():
        date = key[1:].replace("_", "-")
        steps = kw.pop("steps", 8000)
        d = day(date=date, steps=steps, **kw)
        d.steps = series([steps / 96] * 96, interval=15, date=date)
        store.put_day(d, KEY)


def test_each_range_has_its_buckets(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_17={})
    counts = {r: len(history(store, "steps", r, "2026-09-18", NOW)["buckets"]) for r in ("W", "M", "6M", "Y")}
    assert counts == {"W": 7, "M": 30, "6M": 26, "Y": 12}


def test_a_week_is_the_seven_days_ending_on_the_end(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_17={})
    buckets = history(store, "steps", "W", "2026-09-18", NOW)["buckets"]
    assert (buckets[0]["start"], buckets[-1]["end"]) == ("2026-09-12", "2026-09-18")


def test_a_history_day_is_the_same_day_the_pill_shows(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_15={}, d2026_09_16={}, d2026_09_17={})
    summary, pill = day_summary(store, "2026-09-16", NOW), cycle(store, "2026-09-16", NOW)
    assert summary["steps"] == pill["stats"]["steps"]
    assert summary["hr_avg"] == pill["stats"]["hr_avg"]


def test_an_unmeasured_day_is_none_not_zero(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_17={})
    first = history(store, "heart_rate", "W", "2026-09-18", NOW)["buckets"][0]
    assert first["value"] is None and first["days"] == 0


def test_heart_rate_buckets_carry_the_days_range(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_17={"hr": [0] * 60 + [52] * 12 + [70] * 90 + [141] * 10})
    bucket = next(b for b in history(store, "heart_rate", "W", "2026-09-18", NOW)["buckets"] if b["days"])
    assert (bucket["low"], bucket["high"]) == (52.0, 141.0)
    assert 52 < bucket["value"] < 141


def test_a_week_bucket_averages_only_the_days_measured(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_15={"steps": 6000}, d2026_09_17={"steps": 10000})
    week = history(store, "steps", "6M", "2026-09-18", NOW)["buckets"][-1]
    assert week["days"] >= 2
    assert week["value"] is not None and 5000 < week["value"] < 11000


def test_sleep_buckets_carry_the_nights_stages(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_17={})
    bucket = next(b for b in history(store, "sleep", "W", "2026-09-18", NOW)["buckets"] if b["days"])
    assert bucket["stages"]["deep"] > 0 and bucket["stages"]["rem"] > 0
    assert bucket["value"] == 480


def test_sleep_debt_is_the_running_week_on_each_day(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_16={"asleep": 360}, d2026_09_17={"asleep": 420})
    out = history(store, "sleep_debt", "W", "2026-09-18", NOW)
    by_day = {b["start"]: b["value"] for b in out["buckets"]}
    assert (by_day["2026-09-16"], by_day["2026-09-17"]) == (120, 180)
    assert out["headline"]["value"] == 180


def test_the_highlight_compares_with_the_period_before(tmp_registry):
    store = HealthStore()
    # The week before averages ~70 bpm; this week ~80.
    _stored(store, d2026_09_08={"hr": [70] * 288}, d2026_09_17={"hr": [80] * 288})
    text = history(store, "heart_rate", "W", "2026-09-18", NOW)["highlight"]
    assert "higher than the 7 days before" in text and "bpm" in text


def test_the_highlight_says_lower_too(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_08={"hr": [80] * 288}, d2026_09_17={"hr": [70] * 288})
    assert "lower than" in history(store, "heart_rate", "W", "2026-09-18", NOW)["highlight"]


def test_with_nothing_to_compare_it_says_how_much_history_there_is(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_17={})
    text = history(store, "heart_rate", "W", "2026-09-18", NOW)["highlight"]
    assert "1 day" in text and "so far" in text


def test_stats_per_metric(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_16={"steps": 6000}, d2026_09_17={"steps": 10000})
    stats = {s["label"]: s for s in history(store, "steps", "W", "2026-09-18", NOW)["stats"]}
    assert {"Total", "Daily average", "Best day", "Days measured"} <= set(stats)
    assert stats["Days measured"]["value"] == 2


def test_goal_rings_judge_each_night_against_the_sleep_goal(tmp_registry):
    store = HealthStore()
    _stored(store, d2026_09_16={"asleep": 360}, d2026_09_17={"asleep": 500})
    out = history(store, "sleep_debt", "W", "2026-09-18", NOW)
    progress = {b["start"]: b["goal_progress"] for b in out["buckets"]}
    assert progress["2026-09-16"] == 0.75 and progress["2026-09-17"] > 1
    assert progress["2026-09-12"] is None, "no night, no ring"
    assert out["goal"] == {"value": 480.0, "kind": "minutes", "met": 1, "measured": 2}


def test_steps_are_judged_against_the_step_goal_and_long_ranges_have_no_rings(tmp_registry):
    store = HealthStore()
    store.put_settings({"goals": {"steps": 8000}})
    _stored(store, d2026_09_17={"steps": 4000})
    week = history(store, "steps", "W", "2026-09-18", NOW)
    assert week["goal"]["value"] == 8000
    assert history(store, "steps", "6M", "2026-09-18", NOW)["goal"] is None
    assert history(store, "heart_rate", "W", "2026-09-18", NOW)["goal"] is None
