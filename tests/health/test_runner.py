"""One run: fetch, store, score, rules, prose, push."""
from jarvis_health.runner import run as _run_all
from jarvis_health.sources import SourceUnreachable
from jarvis_health.store import HealthStore

KEY = "ring-aaaa0000"

from .fixtures import day


class FakeSource:
    kind = "ring"

    def __init__(self, the_day=None, unreachable=False):
        self._day = the_day or day()
        self._unreachable = unreachable
        self.fetched = 0

    def identity(self):
        return {"kind": "ring", "device_id": "dev-1", "name": "R12"}

    def eligible(self):
        return True

    def fetch_day(self, date, tz):
        self.fetched += 1
        if self._unreachable:
            raise SourceUnreachable("the phone is not reachable")
        return self._day

    def backfill(self, days):
        return []

    def battery(self):
        return {"percent": 60, "charging": False}


def run(source, **kwargs):
    """One run with this source as the ring, registered and linked first."""
    store = HealthStore()
    if not store.roster():
        store.upsert_device({"kind": "ring", "device_id": "aaaa0000", "name": "R12"})
    return _run_all(sources={KEY: source}, **kwargs)


def no_model(**kwargs):
    return "Slept 6h29m, HRV above your usual."


def pushes():
    sent = []
    return sent, lambda alerts, space_id, settings: sent.extend(alerts)


def test_a_run_stores_the_day_scores_and_analysis(tmp_registry):
    sent, notify = pushes()
    out = run(FakeSource(), trigger="manual", call=no_model, notify=notify,
              now="2026-09-17T17:00:00Z")

    assert out["stale"] is False
    assert out["scores"]["health"]["value"] is not None
    store = HealthStore()
    assert store.day("2026-09-17", KEY) is not None
    assert store.scores("2026-09-17")["analysis"] == "Slept 6h29m, HRV above your usual."
    assert store.runs(limit=5)[0]["trigger"] == "manual"


def test_the_baseline_is_rebuilt_from_stored_days(tmp_registry):
    store = HealthStore()
    for date in ("2026-09-13", "2026-09-14", "2026-09-15", "2026-09-16"):
        store.put_day(day(date=date, hrv=44), KEY)
    sent, notify = pushes()
    run(FakeSource(day(hrv=44)), call=no_model, notify=notify, now="2026-09-17T17:00:00Z")
    assert HealthStore().baseline().days_used >= 4


def test_an_unreachable_device_scores_the_newest_stored_day_and_raises_nothing(tmp_registry):
    store = HealthStore()
    store.put_day(day(date="2026-09-16"), KEY)
    sent, notify = pushes()

    out = run(FakeSource(unreachable=True), call=no_model, notify=notify,
              now="2026-09-17T17:00:00Z")

    assert out["stale"] is True
    assert out["alerts"] == []
    assert sent == []
    assert out["scored_date"] == "2026-09-16"


def test_an_unreachable_device_with_nothing_stored_says_so(tmp_registry):
    sent, notify = pushes()
    out = run(FakeSource(unreachable=True), call=no_model, notify=notify)
    assert out["skipped"] == "unreachable"


def test_a_disabled_integration_does_nothing(tmp_registry):
    HealthStore().put_settings({"enabled": False})
    source = FakeSource()
    out = run(source, call=no_model, notify=lambda *a: None)
    assert out["skipped"] == "disabled"
    assert source.fetched == 0


def test_alerts_fire_once_and_are_pushed(tmp_registry):
    short = day(asleep=120)
    sent, notify = pushes()
    first = run(FakeSource(short), call=no_model, notify=notify, now="2026-09-17T17:00:00Z")
    assert "short_sleep" in [a["rule"] for a in first["alerts"]]
    assert sent

    sent.clear()
    second = run(FakeSource(short), call=no_model, notify=notify, now="2026-09-17T18:00:00Z")
    assert second["alerts"] == []
    assert sent == []


def test_an_alert_held_for_quiet_hours_goes_out_on_the_first_run_after(tmp_registry):
    """The bug this pins: held, then suppressed by the one-per-day rule, never seen."""
    short = day(asleep=120)
    sent, notify = pushes()

    # 02:00 local — inside quiet hours, so nothing may be pushed yet.
    night = run(FakeSource(short), call=no_model, notify=notify,
                now="2026-09-17T07:00:00Z")
    assert [a["rule"] for a in night["held"]] == ["short_sleep"]
    assert sent == []

    # 12:00 local — the window has passed, so the held alert arrives.
    sent.clear()
    morning = run(FakeSource(short), call=no_model, notify=notify,
                  now="2026-09-17T17:00:00Z")
    assert [a["rule"] for a in morning["released"]] == ["short_sleep"]
    # A two-hour night charges nothing, so by noon the battery alert fires too.
    assert "short_sleep" in [a.rule for a in sent]


def test_a_released_alert_is_not_released_twice(tmp_registry):
    short = day(asleep=120)
    sent, notify = pushes()
    run(FakeSource(short), call=no_model, notify=notify, now="2026-09-17T07:00:00Z")
    run(FakeSource(short), call=no_model, notify=notify, now="2026-09-17T17:00:00Z")

    sent.clear()
    again = run(FakeSource(short), call=no_model, notify=notify,
                now="2026-09-17T18:00:00Z")
    assert again["released"] == []
    assert sent == []


def test_with_every_wearable_unlinked_nothing_runs(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.set_linked(KEY, False)
    out = _run_all(sources={}, call=no_model, notify=lambda *a: None)
    assert out["skipped"] == "no linked wearables"


def test_every_linked_wearable_is_synced(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.upsert_device({"kind": "ring", "device_id": "bbbb0000"})
    a, b = FakeSource(), FakeSource()
    _run_all(sources={KEY: a, "ring-bbbb0000": b}, call=no_model, notify=lambda *x: None,
             now="2026-09-17T17:00:00Z")
    assert (a.fetched, b.fetched) == (1, 1)
    assert set(store.device_days("2026-09-17")) == {KEY, "ring-bbbb0000"}


def test_a_run_stores_the_day_battery_and_chains_from_yesterday(tmp_registry):
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.put_battery("2026-09-16", {"end_level": 30})
    out = run(FakeSource(day()), call=no_model, notify=lambda *a: None, now="2026-09-18T04:59:00Z")
    battery = store.battery("2026-09-17")
    assert battery["start_level"] == 30
    assert out["scores"]["health"]["value"] == round(battery["level"])
    assert out["scores"]["health"]["band"] == battery["band"], "the battery's own bands"
    assert store.scores("2026-09-17")["health"]["band"] == battery["band"]
