"""Today: from falling asleep last night to now, a window that does not reset at midnight."""
from datetime import datetime

from jarvis_health.store import HealthStore
from jarvis_health.window import last_night, today, window_day, window_stats

from .fixtures import day


def _utc(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def test_the_last_main_sleep_is_last_night():
    d = day(asleep=480)
    assert last_night([d], _utc("2026-09-17T20:00:00Z")) is d.main_sleep


def test_a_nap_does_not_reset_the_window():
    d = day(asleep=480)
    d.sleep.append(day(asleep=60).sleep[0])
    assert last_night([d], _utc("2026-09-18T02:00:00Z")) is d.main_sleep


def test_the_window_crosses_midnight():
    today, tomorrow = day(date="2026-09-17"), day(date="2026-09-18", asleep=0)
    start, end = _utc("2026-09-17T13:00:00Z"), _utc("2026-09-18T07:00:00Z")   # 08:00 → 02:00 local
    w = window_day({"2026-09-17": today, "2026-09-18": tomorrow}, start, end)
    assert len(w.stress.values) > 48
    assert window_stats(w)["stress_avg"] == 40.0


def test_today_reads_the_battery_curve_to_now(tmp_registry):
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
    out = today(store, "2026-09-17T16:00:00Z")
    assert out["no_wake"] is False
    assert out["battery"]["level"] == 74.0
    assert out["battery"]["drained"] > 0
    assert out["battery"]["biggest_drain"]["points"] == 6.0
    assert out["stats"]["hr_avg"] is not None


def test_with_no_sleep_at_all_the_window_starts_at_midnight(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.put_day(day(asleep=0), "ring-aaaa0000")
    assert today(store, "2026-09-17T16:00:00Z")["no_wake"] is True


def test_without_a_steps_series_the_day_totals_stand_in():
    today = day(date="2026-09-17", steps=4321)
    w = window_day({"2026-09-17": today}, _utc("2026-09-17T13:00:00Z"), _utc("2026-09-17T20:00:00Z"))
    assert w.activity["steps"] == 4321


def test_the_night_that_opened_the_window_is_part_of_it(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    d = day(asleep=480)
    store.put_day(d, "ring-aaaa0000")
    out = today(store, "2026-09-17T20:00:00Z")
    sleeps = out["day"]["sleep"]
    assert [s["end"] for s in sleeps] == [d.main_sleep.end], "last night, so the sleep card has it"


def _stored(store, *days):
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    for d in days:
        store.put_day(d, "ring-aaaa0000")


def test_today_runs_from_falling_asleep_to_now(tmp_registry):
    store = HealthStore()
    d = day(asleep=480)                       # 23:30 → 07:37 local
    _stored(store, d)
    out = today(store, "2026-09-17T20:00:00Z")
    assert out["start"] == d.main_sleep.start
    assert out["wake"] == d.main_sleep.end
    assert out["no_wake"] is False
    assert out["minutes"] == 930


def test_a_night_more_than_a_day_old_is_not_last_night(tmp_registry):
    store = HealthStore()
    _stored(store, day(asleep=480))           # woke 2026-09-17 07:37 local
    out = today(store, "2026-09-18T14:00:00Z")
    assert out["no_wake"] is True
    assert out["wake"] is None
    assert out["start"] == "2026-09-18T05:00:00Z", "the ring was off last night: today's midnight"
    assert out["battery"]["no_sleep"] is True


def test_todays_battery_charges_overnight_then_drains(tmp_registry):
    store = HealthStore()
    _stored(store, day(asleep=480))           # in bed 04:30Z, awake 12:37Z
    store.put_battery("2026-09-16", {"curve": [
        {"at": "2026-09-17T04:00:00Z", "level": 40.0},
        {"at": "2026-09-17T04:30:00Z", "level": 39.5},
    ]})
    store.put_battery("2026-09-17", {"recovery_factor": 1.02, "curve": [
        {"at": "2026-09-17T05:00:00Z", "level": 45.0},
        {"at": "2026-09-17T13:00:00Z", "level": 90.0},
        {"at": "2026-09-17T15:00:00Z", "level": 86.0},
        {"at": "2026-09-17T15:30:00Z", "level": 84.0},
    ]})
    b = today(store, "2026-09-17T16:00:00Z")["battery"]
    assert b["curve"][0]["at"] == "2026-09-17T04:30:00Z", "from the level at bedtime"
    assert (b["bed_level"], b["wake_level"], b["level"]) == (39.5, 90.0, 84.0)
    assert b["charged"] == 50.5
    assert b["drained"] == 6.0
    assert b["bed_at"] == "2026-09-17T04:30:00Z" and b["wake_at"] == "2026-09-17T12:37:00Z"
    assert b["recovery_factor"] == 1.02
