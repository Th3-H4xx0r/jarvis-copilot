"""The ring adapter: skill JSON in, a HealthDay out."""
import pytest

from jarvis_health.metrics import STAGE_AWAKE, STAGE_DEEP, STAGE_LIGHT
from jarvis_health.sources import ELIGIBLE_KINDS, SourceUnreachable
from jarvis_health.sources.ring import RingSource

# The ring's own stage codes: 2 light, 3 deep, 4 REM, 5 awake.
DAY = {
    "date": "2026-09-17",
    "timezone": "America/Chicago",
    "sleep": [
        {
            "start": "2026-09-17T05:23:00Z",
            "end": "2026-09-17T11:59:00Z",
            "stages": [
                {"stage": 3, "minutes": 68},
                {"stage": 2, "minutes": 273},
                {"stage": 4, "minutes": 48},
                {"stage": 5, "minutes": 7},
            ],
        }
    ],
    "heart_rate": {"interval_minutes": 5, "values": [0, 70, 72]},
    "hrv": {"interval_minutes": 30, "values": [40, 44]},
    "stress": {"interval_minutes": 30, "values": [30, 62]},
    "spo2": {"max": [98, 97], "min": [96, 95]},
    "activity": {"steps": 4200, "active_minutes": 25},
    "battery_percent": 16,
    "charging": False,
}


def fake_invoke(answers):
    def invoke(device_id, skill, args=None, timeout=30):
        if skill not in answers:
            return {"ok": True, "result": {}}
        return answers[skill]
    return invoke


def test_the_ring_is_an_eligible_health_source():
    assert "ring" in ELIGIBLE_KINDS
    assert RingSource("dev-1", invoke=fake_invoke({})).eligible() is True


def test_ring_source_maps_skill_json_onto_a_health_day():
    src = RingSource("dev-1", invoke=fake_invoke({
        "wearables_connect": {"ok": True, "result": {"connected": True}},
        "ring_sync": {"ok": True, "result": {"updated": ["sleep"]}},
        "ring_get_health_day": {"ok": True, "result": DAY},
    }))
    day = src.fetch_day("2026-09-17", "America/Chicago")

    assert day.date == "2026-09-17"
    assert day.timezone == "America/Chicago"
    assert day.utc_offset == -18000
    # Translated onto the SDK's vocabulary: the ring's 3 is deep, its 2 is light.
    assert day.main_sleep.stage_minutes(STAGE_DEEP) == 68
    assert day.main_sleep.stage_minutes(STAGE_LIGHT) == 273
    assert day.main_sleep.stage_minutes(STAGE_AWAKE) == 7
    assert day.main_sleep.asleep_minutes == 389
    assert day.main_sleep.awakenings == 1
    assert day.heart_rate.interval_minutes == 5
    assert day.heart_rate.start == "2026-09-17T05:00:00Z"
    assert day.hrv.values == [40, 44]
    assert day.spo2.values == [97, 96]        # the band's midpoint per hour
    assert day.activity["steps"] == 4200
    assert day.battery["percent"] == 16
    assert day.source == "ring"
    assert day.synced_at


def test_a_ring_that_cannot_be_reached_is_unreachable_not_an_empty_day():
    src = RingSource("dev-1", invoke=fake_invoke({
        "wearables_connect": {"ok": False, "error": "not connected"},
        "ring_sync": {"ok": False, "error": "ring is not connected over Bluetooth"},
        "ring_get_health_day": {"ok": False, "error": "not connected"},
    }))
    with pytest.raises(SourceUnreachable):
        src.fetch_day("2026-09-17", "America/Chicago")


def test_a_ring_that_answers_without_data_still_gives_a_day():
    src = RingSource("dev-1", invoke=fake_invoke({
        "ring_sync": {"ok": True, "result": {}},
        "ring_get_health_day": {"ok": True, "result": {"date": "2026-09-17"}},
    }))
    day = src.fetch_day("2026-09-17", "America/Chicago")
    assert day.has("sleep") is False
    assert day.has("activity") is False


def test_backfill_pages_history_in_chunks_the_skill_accepts():
    calls = []

    def invoke(device_id, skill, args=None, timeout=30):
        calls.append((skill, dict(args or {})))
        if skill == "ring_get_history":
            return {"ok": True, "result": {"days": [{"date": "2026-09-16", "summary": {"steps": 10}}]}}
        return {"ok": True, "result": {}}

    days = RingSource("dev-1", invoke=invoke).backfill(45)
    history = [args for skill, args in calls if skill == "ring_get_history"]
    assert history and all(a["days"] <= 30 for a in history)
    assert days and days[0].date == "2026-09-16"


def test_identity_names_the_device_and_its_kind():
    ident = RingSource("dev-1", invoke=fake_invoke({
        "ring_get_status": {"ok": True, "result": {"name": "R12_7E04", "model": "Colmi R12",
                                                   "firmware_version": "RT12_3.10.06_260429"}}})).identity()
    assert ident["kind"] == "ring"
    assert ident["device_id"] == "dev-1"
    assert ident["name"] == "R12_7E04"


def test_the_bridge_prefers_the_in_process_path_inside_the_webui(monkeypatch):
    """A loopback call made while handling a request waits on itself.

    Inside the webui the bridge is importable and authoritative, so the call
    goes straight to it; a run that went out over HTTP instead timed out and
    reported a ring that had answered perfectly well.
    """
    import sys
    import types

    from jarvis_health import bridge

    calls = []
    fake = types.ModuleType("api.device_bridge")
    fake.in_process_available = lambda: True
    fake.invoke_skill = lambda device_id, skill, args, timeout=30: (
        calls.append((device_id, skill)) or {"ok": True, "result": {"in_process": True}}
    )
    api = types.ModuleType("api")
    api.device_bridge = fake
    monkeypatch.setitem(sys.modules, "api", api)
    monkeypatch.setitem(sys.modules, "api.device_bridge", fake)

    def explode(*a, **k):
        raise AssertionError("must not go over loopback inside the webui")

    monkeypatch.setattr(bridge, "request", explode)

    assert bridge.invoke("phone-1", "ring_get_status", {}, 10)["result"]["in_process"] is True
    assert calls == [("phone-1", "ring_get_status")]
