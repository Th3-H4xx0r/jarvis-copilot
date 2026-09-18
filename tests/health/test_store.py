"""The integration space is where a day lives once the server has it."""
from jarvis_health.metrics import Baseline
from jarvis_health.store import DEFAULT_SETTINGS, SHARED_SPACE, HealthStore, device_key_for, space_id_for

from .fixtures import day


def test_device_keys_are_short_and_stable():
    assert device_key_for("ring", "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20") == "ring-b6ce93c4"
    assert space_id_for("ring", "b6ce93c4") == "wearable-ring-b6ce93c4"


def test_the_shared_space_is_protected(tmp_registry):
    store = HealthStore()
    assert store.space_id == SHARED_SPACE
    assert store.put_settings({})["protected"] is True


def test_settings_start_from_defaults_and_merge_updates(tmp_registry):
    store = HealthStore()
    assert store.settings()["enabled"] is True
    assert store.settings()["frequency"] == DEFAULT_SETTINGS["frequency"]
    assert store.settings()["rules"]["short_sleep"]["enabled"] is True

    store.put_settings({"model": "claude-opus-5"})
    assert store.settings()["model"] == "claude-opus-5"
    assert store.settings()["enabled"] is True, "an update must not drop the rest"


def test_a_rule_threshold_can_be_changed_without_losing_the_other_rules(tmp_registry):
    store = HealthStore()
    store.put_settings({"rules": {"short_sleep": {"threshold": 4.0}}})
    rules = store.settings()["rules"]
    assert rules["short_sleep"]["threshold"] == 4.0
    assert rules["short_sleep"]["enabled"] is True
    assert "spo2_low" in rules


def test_days_are_kept_per_device_and_upsert(tmp_registry):
    store = HealthStore()
    store.put_day(day(steps=100), "ring-aaaa0000")
    store.put_day(day(steps=200), "watch-bbbb0000")
    store.put_day(day(steps=300), "ring-aaaa0000")
    both = store.device_days("2026-09-17")
    assert set(both) == {"ring-aaaa0000", "watch-bbbb0000"}
    assert both["ring-aaaa0000"].activity["steps"] == 300


def test_dates_come_back_newest_first(tmp_registry):
    store = HealthStore()
    for date in ("2026-09-15", "2026-09-17", "2026-09-16"):
        store.put_day(day(date=date), "ring-aaaa0000")
    assert store.dates() == ["2026-09-17", "2026-09-16", "2026-09-15"]


def test_a_device_joins_linked_and_keeps_its_link_state(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000-x", "name": "R12"})
    store.set_linked("ring-aaaa0000", False)
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000-x", "name": "Ring"})
    (entry,) = store.roster()
    assert entry["name"] == "Ring" and entry["linked"] is False
    assert store.linked() == []


def test_battery_round_trips(tmp_registry):
    store = HealthStore()
    store.put_battery("2026-09-17", {"end_level": 31})
    assert store.battery("2026-09-17") == {"end_level": 31}


def test_scores_and_baseline_round_trip(tmp_registry):
    store = HealthStore()
    store.put_scores("2026-09-17", {"health": {"value": 78}, "analysis": "Slept short."})
    store.put_baseline(Baseline(hrv=45, resting_hr=58, days_used=14))
    assert store.scores("2026-09-17")["health"]["value"] == 78
    assert store.baseline().resting_hr == 58
    assert store.scores("2026-09-01") is None


def test_runs_and_alerts_append_and_alerts_are_counted_per_day(tmp_registry):
    store = HealthStore()
    store.log_run({"trigger": "cron"})
    store.log_run({"trigger": "manual"})
    store.log_alert({"rule": "short_sleep", "date": "2026-09-17"})
    assert len(store.runs(limit=10)) == 2
    assert store.fired_today("2026-09-17") == {"short_sleep"}
    assert store.fired_today("2026-09-16") == set()
