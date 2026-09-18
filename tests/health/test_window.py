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


def test_without_a_steps_series_a_day_counts_the_share_the_window_covers():
    today = day(date="2026-09-17", steps=4800)
    w = window_day({"2026-09-17": today}, _utc("2026-09-17T13:00:00Z"), _utc("2026-09-17T19:00:00Z"))
    assert w.activity["steps"] == 1200, "6 of 24 hours"


def test_a_day_with_a_series_and_one_without_both_count():
    from .fixtures import series
    with_series = day(date="2026-09-18", steps=960)
    with_series.steps = series([10] * 96, interval=15, date="2026-09-18")
    totals_only = day(date="2026-09-17", steps=4800)
    # 12:00 on the 17th → 06:00 on the 18th, local (UTC−5).
    w = window_day({"2026-09-17": totals_only, "2026-09-18": with_series},
                   _utc("2026-09-17T17:00:00Z"), _utc("2026-09-18T11:00:00Z"))
    assert w.activity["steps"] == 2400 + 240, "half the 17th's total, and the 18th's slots to 06:00"


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


def test_the_slot_still_running_is_the_level_now(tmp_registry):
    # A run at 16:10 charts the slot 16:00–16:30 and stamps it 16:30: that is
    # the level the score reports, so today must end on it too.
    store = HealthStore()
    _stored(store, day(asleep=480))
    store.put_battery("2026-09-17", {"curve": [
        {"at": "2026-09-17T16:00:00Z", "level": 84.0},
        {"at": "2026-09-17T16:30:00Z", "level": 83.0},
    ]})
    assert today(store, "2026-09-17T16:10:00Z")["battery"]["level"] == 83.0


def _up_late():
    """The 17th's night began 23:30 on the 16th; the 18th's began at 02:00 on the 18th."""
    return day(date="2026-09-17"), day(date="2026-09-18", bedtime_minute=120, hr=[66] * 288)


def test_a_day_runs_to_the_bedtime_after_midnight(tmp_registry):
    from jarvis_health.window import cycle

    store = HealthStore()
    yesterday, late = _up_late()
    _stored(store, yesterday, late)
    out = cycle(store, "2026-09-17", "2026-09-18T20:00:00Z")
    assert out["start"] == yesterday.main_sleep.start
    assert out["end"] == late.main_sleep.start == "2026-09-18T07:00:00Z"
    # The hours up past midnight (00:00–02:00 on the 18th) are in the 17th.
    hr = out["day"]["heart_rate"]
    first = 2 * 288   # the 18th's local midnight, in 5-minute slots from the 16th's
    assert any(v > 0 for v in hr["values"][first:first + 24])
    assert out["date"] == "2026-09-17" and out["no_wake"] is False


def test_one_day_ends_where_today_begins(tmp_registry):
    from jarvis_health.window import cycle

    store = HealthStore()
    _stored(store, *_up_late())
    now = "2026-09-18T20:00:00Z"
    current = today(store, now)
    assert current["date"] == "2026-09-18"
    assert cycle(store, "2026-09-17", now)["end"] == current["start"]


def test_without_the_next_night_a_day_ends_at_midnight(tmp_registry):
    from jarvis_health.window import cycle

    store = HealthStore()
    _stored(store, day(date="2026-09-17"))
    out = cycle(store, "2026-09-17", "2026-09-19T12:00:00Z")
    assert out["end"] == "2026-09-18T05:00:00Z"


def test_a_finished_day_stops_before_the_next_nights_charge(tmp_registry):
    from jarvis_health.window import cycle

    store = HealthStore()
    _stored(store, *_up_late())
    store.put_battery("2026-09-18", {"curve": [
        {"at": "2026-09-18T06:30:00Z", "level": 40.0},
        {"at": "2026-09-18T07:00:00Z", "level": 39.5},     # bedtime
        {"at": "2026-09-18T07:30:00Z", "level": 43.0},     # charging: tomorrow's
    ]})
    b = cycle(store, "2026-09-17", "2026-09-18T20:00:00Z")["battery"]
    assert b["curve"][-1]["at"] == "2026-09-18T07:00:00Z"
    assert b["level"] == 39.5
