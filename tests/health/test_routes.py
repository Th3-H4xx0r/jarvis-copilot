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
