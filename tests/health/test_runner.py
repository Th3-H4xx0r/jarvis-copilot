"""One run: fetch, store, score, rules, prose, push."""
from jarvis_health.runner import run
from jarvis_health.sources import SourceUnreachable
from jarvis_health.store import HealthStore

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


def no_model(**kwargs):
    return "Slept 6h29m, HRV above your usual."


def pushes():
    sent = []
    return sent, lambda alerts, space_id, settings: sent.extend(alerts)


def test_a_run_stores_the_day_scores_and_analysis(tmp_registry):
    sent, notify = pushes()
    out = run("wearable-ring-test", FakeSource(), trigger="manual", call=no_model, notify=notify,
              now="2026-09-17T17:00:00Z")

    assert out["stale"] is False
    assert out["scores"]["health"]["value"] is not None
    store = HealthStore("wearable-ring-test")
    assert store.day("2026-09-17") is not None
    assert store.scores("2026-09-17")["analysis"] == "Slept 6h29m, HRV above your usual."
    assert store.runs(limit=5)[0]["trigger"] == "manual"


def test_the_baseline_is_rebuilt_from_stored_days(tmp_registry):
    store = HealthStore("wearable-ring-test")
    for date in ("2026-09-13", "2026-09-14", "2026-09-15", "2026-09-16"):
        store.put_day(day(date=date, hrv=44))
    sent, notify = pushes()
    run("wearable-ring-test", FakeSource(day(hrv=44)), call=no_model, notify=notify, now="2026-09-17T17:00:00Z")
    assert HealthStore("wearable-ring-test").baseline().days_used >= 4


def test_an_unreachable_device_scores_the_newest_stored_day_and_raises_nothing(tmp_registry):
    store = HealthStore("wearable-ring-test")
    store.put_day(day(date="2026-09-16"))
    sent, notify = pushes()

    out = run("wearable-ring-test", FakeSource(unreachable=True), call=no_model, notify=notify,
              now="2026-09-17T17:00:00Z")

    assert out["stale"] is True
    assert out["alerts"] == []
    assert sent == []
    assert out["scored_date"] == "2026-09-16"


def test_an_unreachable_device_with_nothing_stored_says_so(tmp_registry):
    sent, notify = pushes()
    out = run("wearable-ring-test", FakeSource(unreachable=True), call=no_model, notify=notify)
    assert out["skipped"] == "unreachable"


def test_a_disabled_integration_does_nothing(tmp_registry):
    HealthStore("wearable-ring-test").put_settings({"enabled": False})
    source = FakeSource()
    out = run("wearable-ring-test", source, call=no_model, notify=lambda *a: None)
    assert out["skipped"] == "disabled"
    assert source.fetched == 0


def test_alerts_fire_once_and_are_pushed(tmp_registry):
    short = day(asleep=120)
    sent, notify = pushes()
    first = run("wearable-ring-test", FakeSource(short), call=no_model, notify=notify, now="2026-09-17T17:00:00Z")
    assert "short_sleep" in [a["rule"] for a in first["alerts"]]
    assert sent

    sent.clear()
    second = run("wearable-ring-test", FakeSource(short), call=no_model, notify=notify, now="2026-09-17T18:00:00Z")
    assert second["alerts"] == []
    assert sent == []
