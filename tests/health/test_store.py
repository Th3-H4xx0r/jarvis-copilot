"""The integration space is where a day lives once the server has it."""
from jarvis_health.metrics import Baseline
from jarvis_health.store import DEFAULT_SETTINGS, HealthStore, space_id_for

from .fixtures import day


def test_space_ids_are_short_and_stable():
    assert space_id_for("ring", "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20") == "wearable-ring-b6ce93c4"
    assert space_id_for("ring", "b6ce93c4") == "wearable-ring-b6ce93c4"


def test_settings_start_from_defaults_and_merge_updates(tmp_registry):
    store = HealthStore("wearable-ring-test")
    assert store.settings()["enabled"] is True
    assert store.settings()["frequency"] == DEFAULT_SETTINGS["frequency"]
    assert store.settings()["rules"]["short_sleep"]["enabled"] is True

    store.put_settings({"model": "claude-opus-5"})
    assert store.settings()["model"] == "claude-opus-5"
    assert store.settings()["enabled"] is True, "an update must not drop the rest"


def test_a_rule_threshold_can_be_changed_without_losing_the_other_rules(tmp_registry):
    store = HealthStore("wearable-ring-test")
    store.put_settings({"rules": {"short_sleep": {"threshold": 4.0}}})
    rules = store.settings()["rules"]
    assert rules["short_sleep"]["threshold"] == 4.0
    assert rules["short_sleep"]["enabled"] is True
    assert "spo2_low" in rules


def test_a_day_upserts_rather_than_accumulating(tmp_registry):
    store = HealthStore("wearable-ring-test")
    store.put_day(day(steps=100))
    store.put_day(day(steps=900))
    assert store.day("2026-09-17").activity["steps"] == 900
    assert len(store.recent_days(30)) == 1


def test_recent_days_come_back_newest_first(tmp_registry):
    store = HealthStore("wearable-ring-test")
    store.put_day(day(date="2026-09-15"))
    store.put_day(day(date="2026-09-17"))
    assert [d.date for d in store.recent_days(30)] == ["2026-09-17", "2026-09-15"]


def test_scores_and_baseline_round_trip(tmp_registry):
    store = HealthStore("wearable-ring-test")
    store.put_scores("2026-09-17", {"health": {"value": 78}, "analysis": "Slept short."})
    store.put_baseline(Baseline(hrv=45, resting_hr=58, days_used=14))
    assert store.scores("2026-09-17")["health"]["value"] == 78
    assert store.baseline().resting_hr == 58
    assert store.scores("2026-09-01") is None


def test_runs_and_alerts_append_and_alerts_are_counted_per_day(tmp_registry):
    store = HealthStore("wearable-ring-test")
    store.log_run({"trigger": "cron"})
    store.log_run({"trigger": "manual"})
    store.log_alert({"rule": "short_sleep", "date": "2026-09-17"})
    assert len(store.runs(limit=10)) == 2
    assert store.fired_today("2026-09-17") == {"short_sleep"}
    assert store.fired_today("2026-09-16") == set()
