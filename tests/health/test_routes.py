"""The HTTP face of Jarvis Health: one space, edited only from the Health tab."""
import json
from urllib.parse import urlparse

import pytest

from jarvis_health.store import SHARED_SPACE, HealthStore

from .fixtures import day

BASE = "/api/integrations/jarvis-health/health"


class _Handler:
    status = None
    body = None


@pytest.fixture
def routes(tmp_registry, monkeypatch):
    import api.health_routes as routes
    import api.helpers as helpers

    def j(handler, body, status=200):
        handler.status, handler.body = status, json.loads(json.dumps(body, default=str))

    monkeypatch.setattr(helpers, "j", j)
    monkeypatch.setattr("jarvis_health.bootstrap.ensure_schedule", lambda *a, **k: None)
    return routes


def _get(routes, url):
    handler = _Handler()
    assert routes.handle_get(handler, urlparse(url))
    return handler


def _post(routes, url, body):
    handler = _Handler()
    assert routes.handle_post(handler, urlparse(url), body)
    return handler


def _with_ring_day():
    store = HealthStore()
    store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.put_day(day(), "ring-aaaa0000")
    return store


def test_settings_are_written_only_from_the_health_tab(routes):
    HealthStore()
    assert _post(routes, f"{BASE}/settings", {"model": "x"}).status == 403
    assert _post(routes, f"{BASE}/settings", {"source": "wearable-settings", "model": "x"}).status == 403
    ok = _post(routes, f"{BASE}/settings", {"source": "health-settings", "model": "x"})
    assert ok.body["settings"]["model"] == "x"


def test_a_day_comes_back_merged(routes):
    _with_ring_day()
    out = _get(routes, f"{BASE}/day?date=2026-09-17")
    assert out.body["has_data"] and out.body["day"]["activity"]["steps"] == 8000


def test_the_legacy_day_path_still_answers(routes):
    _with_ring_day()
    assert _get(routes, f"{BASE}/day/2026-09-17").body["has_data"] is True


def test_unlinking_a_device_takes_its_data_out(routes):
    _with_ring_day()
    out = _post(routes, f"{BASE}/devices/ring-aaaa0000", {"linked": False})
    assert out.body["device"]["linked"] is False
    assert _get(routes, f"{BASE}/day?date=2026-09-17").body["day"] is None


def test_an_unknown_device_is_404(routes):
    HealthStore()
    assert _post(routes, f"{BASE}/devices/ring-ffff0000", {"linked": False}).status == 404


def test_now_answers_even_with_no_data(routes):
    HealthStore()
    out = _get(routes, f"{BASE}/now")
    assert out.status == 200 and "battery" in out.body


def test_the_phone_registers_wearables_into_the_shared_space(routes):
    out = _post(routes, "/api/health/devices", {"devices": [
        {"kind": "ring", "device_id": "aaaa0000", "bridge_device_id": "p1", "name": "R12"}]})
    assert out.body["space"] == SHARED_SPACE
    listed = _get(routes, "/api/health/devices").body["devices"]
    assert [d["key"] for d in listed] == ["ring-aaaa0000"]


def test_a_pushed_day_is_stored_under_its_device(routes):
    HealthStore().upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    raw = {"date": "2026-09-17", "timezone": "America/Chicago", "source": "ring", "device_id": "aaaa0000",
           "activity": {"steps": 1234}}
    assert _post(routes, f"{BASE}/day", {"day": raw}).body["ok"] is True
    assert HealthStore().day("2026-09-17", "ring-aaaa0000").activity["steps"] == 1234


def test_jarvis_health_cannot_be_deleted(tmp_registry, monkeypatch):
    import api.integrations_routes as integrations

    HealthStore().put_settings({})
    assert integrations._is_protected(SHARED_SPACE) is True


def test_a_day_runs_bedtime_to_bedtime_and_carries_its_sleep_debt(routes):
    _with_ring_day()
    body = _get(routes, f"{BASE}/day?date=2026-09-17").body
    assert body["start"] == day().main_sleep.start, "from the night that ended on it"
    assert body["date"] == "2026-09-17"
    debt = body["sleep_debt"]
    assert debt["goal"] == 480 and len(debt["nights"]) == 7
    assert debt["nights"][-1]["asleep"] == 480


def test_now_names_its_day_and_carries_the_weeks_sleep_debt(routes):
    _with_ring_day()
    body = _get(routes, f"{BASE}/now").body
    assert body["date"] and "sleep_debt" in body


def test_a_day_needs_a_date(routes):
    assert _get(routes, f"{BASE}/day").status == 400


def test_history_answers_for_a_metric_and_range(routes):
    _with_ring_day()
    body = _get(routes, f"{BASE}/history?metric=heart_rate&range=W").body
    assert len(body["buckets"]) == 7 and body["metric"] == "heart_rate"


def test_history_refuses_an_unknown_metric_or_range(routes):
    assert _get(routes, f"{BASE}/history?metric=nope&range=W").status == 400
    assert _get(routes, f"{BASE}/history?metric=steps&range=Q").status == 400


def test_a_saved_workout_shows_on_its_day(routes):
    _with_ring_day()
    workout = {"sport": 7, "sport_name": "Run", "start": "2026-09-17T22:00:00Z", "end": "2026-09-17T22:30:00Z",
               "active_seconds": 1800, "steps": 4200, "heart_rates": [150] * 360}
    assert _post(routes, f"{BASE}/workouts", {"workout": workout, "device_id": "aaaa0000"}).body["ok"] is True
    # Saving it again replaces it rather than doubling it.
    _post(routes, f"{BASE}/workouts", {"workout": workout, "device_id": "aaaa0000"})
    day = _get(routes, f"{BASE}/day?date=2026-09-17").body
    assert [w["sport_name"] for w in day["workouts"]] == ["Run"]


def test_a_workout_needs_its_times(routes):
    assert _post(routes, f"{BASE}/workouts", {"workout": {"sport": 7}}).status == 400


def test_training_documents_round_trip(routes):
    HealthStore()
    template = {"id": "a1", "name": "Push Day", "order": 0, "exercises": []}
    assert _post(routes, f"{BASE}/training/templates", {"template": template}).status == 200
    assert _post(routes, f"{BASE}/training/exercises", {"exercise": {"id": "custom-x", "name": "X"}}).status == 200
    assert _post(routes, f"{BASE}/training/settings", {"settings": {"Plank": {"rest_s": 60}}}).status == 200
    got = _get(routes, f"{BASE}/training").body
    assert got["templates"] == [template]
    assert got["exercises"] == [{"id": "custom-x", "name": "X"}]
    assert got["settings"] == {"Plank": {"rest_s": 60}}
    assert _post(routes, f"{BASE}/training/templates/delete", {"id": "a1"}).body == {"ok": True, "deleted": True}
    assert _post(routes, f"{BASE}/training/exercises/delete", {"id": "custom-x"}).body == {"ok": True, "deleted": True}
    assert _get(routes, f"{BASE}/training").body["templates"] == []


def test_a_bad_training_id_is_a_400(routes):
    HealthStore()
    bad = _post(routes, f"{BASE}/training/templates", {"template": {"id": "No Good", "name": "x"}})
    assert bad.status == 400 and "id" in bad.body["error"]
    assert _post(routes, f"{BASE}/training/templates", {}).status == 400


def test_workouts_list_by_kind_and_delete(routes):
    HealthStore()
    lift = {"sport": 88, "sport_name": "Strength", "start": "2026-09-19T10:00:00Z", "end": "2026-09-19T11:00:00Z",
            "strength": {"name": "Push", "exercises": []}}
    run = {"sport": 7, "sport_name": "Run", "start": "2026-09-19T12:00:00Z", "end": "2026-09-19T12:30:00Z"}
    for w in (lift, run):
        assert _post(routes, f"{BASE}/workouts", {"workout": w, "device_id": "aaaa0000"}).status == 200
    assert len(_get(routes, f"{BASE}/workouts").body["workouts"]) == 2
    lifts = _get(routes, f"{BASE}/workouts?kind=strength").body["workouts"]
    assert [w["sport"] for w in lifts] == [88]
    gone = _post(routes, f"{BASE}/workouts/delete", {"start": "2026-09-19T10:00:00Z", "device_id": "aaaa0000"})
    assert gone.body == {"ok": True, "deleted": True}
    assert [w["sport"] for w in _get(routes, f"{BASE}/workouts").body["workouts"]] == [7]
    # The key the workout came back with works as well.
    device = _get(routes, f"{BASE}/workouts").body["workouts"][0]["device"]
    assert _post(routes, f"{BASE}/workouts/delete", {"start": "2026-09-19T12:00:00Z", "device": device}).body["deleted"]


def test_now_carries_the_resting_heart_rate(routes):
    HealthStore()
    assert "resting_hr" in _get(routes, f"{BASE}/now").body
