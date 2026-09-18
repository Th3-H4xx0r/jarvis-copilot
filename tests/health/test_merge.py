"""The person's day, from however many wearables reported it."""
from jarvis_health.merge import merged_day, merged_recent
from jarvis_health.store import HealthStore

from .fixtures import day


def _store_with(ring_steps=5000, watch_steps=7000):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.upsert_device({"kind": "watch", "device_id": "bbbb0000"})
    store.put_day(day(steps=ring_steps), "ring-aaaa0000")
    store.put_day(day(steps=watch_steps, asleep=0), "watch-bbbb0000")
    return store


def test_the_primary_wearable_supplies_sleep_and_heart(tmp_registry):
    merged = merged_day(_store_with(), "2026-09-17")
    assert merged.source == "ring-aaaa0000"
    assert merged.main_sleep is not None


def test_steps_take_the_highest_count(tmp_registry):
    assert merged_day(_store_with(), "2026-09-17").activity["steps"] == 7000


def test_an_unlinked_device_is_left_out(tmp_registry):
    store = _store_with()
    store.set_linked("watch-bbbb0000", False)
    assert merged_day(store, "2026-09-17").activity["steps"] == 5000


def test_a_metric_only_another_device_has_is_filled_in(tmp_registry):
    store = _store_with()
    ring = store.day("2026-09-17", "ring-aaaa0000")
    ring.spo2 = None
    store.put_day(ring, "ring-aaaa0000")
    assert merged_day(store, "2026-09-17").spo2 is not None


def test_a_chosen_primary_wins(tmp_registry):
    store = _store_with()
    store.put_settings({"primary_device": "watch-bbbb0000"})
    assert merged_day(store, "2026-09-17").source == "watch-bbbb0000"


def test_recent_merged_days_are_newest_first(tmp_registry):
    store = _store_with()
    store.put_day(day(date="2026-09-16"), "ring-aaaa0000")
    assert [d.date for d in merged_recent(store)] == ["2026-09-17", "2026-09-16"]
