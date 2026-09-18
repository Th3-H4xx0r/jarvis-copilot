"""Since you woke: a window that does not reset at midnight."""
from datetime import datetime

from jarvis_health.store import HealthStore
from jarvis_health.window import last_wake, since_wake, window_day, window_stats

from .fixtures import day


def _utc(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def test_the_last_main_sleep_sets_the_wake():
    d = day(asleep=480)
    assert last_wake([d], _utc("2026-09-17T20:00:00Z")) == _utc(d.main_sleep.end)


def test_a_nap_does_not_reset_the_window():
    d = day(asleep=480)
    d.sleep.append(day(asleep=60).sleep[0])
    assert last_wake([d], _utc("2026-09-18T02:00:00Z")) == _utc(d.main_sleep.end)


def test_the_window_crosses_midnight():
    today, tomorrow = day(date="2026-09-17"), day(date="2026-09-18", asleep=0)
    start, end = _utc("2026-09-17T13:00:00Z"), _utc("2026-09-18T07:00:00Z")   # 08:00 → 02:00 local
    w = window_day({"2026-09-17": today, "2026-09-18": tomorrow}, start, end)
    assert len(w.stress.values) > 48
    assert window_stats(w)["stress_avg"] == 40.0


def test_since_wake_reads_the_battery_curve_from_wake_to_now(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    d = day()
    store.put_day(d, "ring-aaaa0000")
    store.put_battery("2026-09-17", {"curve": [
        {"at": "2026-09-17T12:00:00Z", "level": 90.0},
        {"at": "2026-09-17T13:00:00Z", "level": 88.0},
        {"at": "2026-09-17T15:00:00Z", "level": 80.0},
        {"at": "2026-09-17T15:30:00Z", "level": 74.0},
    ]})
    out = since_wake(store, "2026-09-17T16:00:00Z")
    assert out["no_wake"] is False
    assert out["battery"]["level"] == 74.0
    assert out["battery"]["drained"] > 0
    assert out["battery"]["biggest_drain"]["points"] == 6.0
    assert out["stats"]["hr_avg"] is not None


def test_with_no_sleep_at_all_the_window_starts_at_midnight(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.put_day(day(asleep=0), "ring-aaaa0000")
    assert since_wake(store, "2026-09-17T16:00:00Z")["no_wake"] is True
