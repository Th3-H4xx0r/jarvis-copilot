"""The X5 ring as a health source: the R12's adapter, speaking `x5_*` skills."""
import json
from urllib.parse import urlparse

import pytest

from jarvis_health.metrics import STAGE_DEEP, STAGE_LIGHT
from jarvis_health.sources import DAY_KINDS, ELIGIBLE_KINDS, SourceUnreachable, source_for
from jarvis_health.sources.ring import RingSource
from jarvis_health.store import HealthStore

from .test_ring_source import DAY

X5_DAY = {**DAY, "source": "x5ring"}
STATUS = {"name": "X5_1A2B", "model": "X5 smart ring", "firmware_version": "1.0.7",
          "battery_percent": 64, "charging": True}


def recording(answers):
    """An invoke that answers from `answers` and remembers every skill it was asked for."""
    calls = []

    def invoke(device_id, skill, args=None, timeout=30):
        calls.append((device_id, skill, dict(args or {})))
        return answers.get(skill, {"ok": True, "result": {}})

    return calls, invoke


def x5(invoke, bridge="phone-1", wearable="x5-ring"):
    return RingSource(bridge, wearable, invoke=invoke, prefix="x5_", kind="x5ring")


def skills(calls):
    return [skill for _, skill, _ in calls]


def test_the_x5_is_an_eligible_day_syncing_kind():
    assert "x5ring" in ELIGIBLE_KINDS
    assert "x5ring" in DAY_KINDS


def test_source_for_the_x5_is_the_ring_adapter_with_its_own_prefix():
    src = source_for("x5ring", "phone", "ring-id")
    assert isinstance(src, RingSource)
    assert (src.kind, src.prefix) == ("x5ring", "x5_")
    assert (src.bridge_device_id, src.wearable_id) == ("phone", "ring-id")
    # The R12 keeps its own names.
    r12 = source_for("ring", "phone", "ring-id")
    assert (r12.kind, r12.prefix) == ("ring", "ring_")


def test_an_x5_day_is_fetched_with_x5_skills_only():
    calls, invoke = recording({
        "wearables_connect": {"ok": True, "result": {"connected": True}},
        "x5_sync": {"ok": True, "result": {"updated": ["sleep"]}},
        "x5_get_health_day": {"ok": True, "result": X5_DAY},
    })
    day = x5(invoke).fetch_day("2026-09-17", "America/Chicago")

    assert skills(calls) == ["wearables_connect", "x5_sync", "x5_get_health_day"]
    assert all(device == "phone-1" for device, _, _ in calls), "skills run on the phone"
    assert calls[0][2] == {"wearable_id": "x5-ring"}, "the hub is told which ring to bring up"
    assert calls[2][2] == {"date": "2026-09-17"}
    # Same stage codes as the R12: 3 deep, 2 light.
    assert day.main_sleep.stage_minutes(STAGE_DEEP) == 68
    assert day.main_sleep.stage_minutes(STAGE_LIGHT) == 273
    assert day.activity["steps"] == 4200
    assert day.source == "x5ring"


def test_an_x5_day_without_a_date_lets_the_phone_choose_it():
    calls, invoke = recording({"x5_get_health_day": {"ok": True, "result": X5_DAY}})
    day = x5(invoke).fetch_day(None, "UTC")
    assert ("phone-1", "x5_get_health_day", {}) in calls
    assert (day.date, day.timezone) == ("2026-09-17", "America/Chicago")


def test_an_unreachable_x5_is_unreachable_not_an_empty_day():
    calls, invoke = recording({
        "wearables_connect": {"ok": False, "error": "not connected"},
        "x5_sync": {"ok": False, "error": "ring is not connected over Bluetooth"},
    })
    with pytest.raises(SourceUnreachable, match="not connected over Bluetooth"):
        x5(invoke).fetch_day("2026-09-17", "America/Chicago")
    assert "x5_get_health_day" not in skills(calls)


def test_x5_identity_and_battery_read_x5_status():
    calls, invoke = recording({"x5_get_status": {"ok": True, "result": STATUS}})
    src = x5(invoke)

    ident = src.identity()
    assert ident["kind"] == "x5ring"
    assert ident["device_id"] == "x5-ring"
    assert ident["bridge_device_id"] == "phone-1"
    assert (ident["name"], ident["model"], ident["firmware"]) == ("X5_1A2B", "X5 smart ring", "1.0.7")
    assert src.battery() == {"percent": 64, "charging": True}
    assert skills(calls) == ["x5_get_status", "x5_get_status"]


def test_x5_backfill_reads_x5_history_and_files_days_as_x5():
    calls, invoke = recording({"x5_get_history": {"ok": True, "result": {"days": [
        {"date": "2026-09-16", "timezone": "America/Chicago", "summary": {"steps": 812, "heart_rate_min": 51}},
        {"summary": {"steps": 1}},  # no date: nothing to file it under
    ]}}})
    days = x5(invoke).backfill(45)

    assert skills(calls) == ["x5_get_history"]
    assert calls[0][2]["days"] <= 30
    assert [(d.date, d.source, d.activity) for d in days] == [("2026-09-16", "x5ring", {"steps": 812})]


def test_the_r12_still_speaks_ring_skills():
    calls, invoke = recording({
        "ring_get_status": {"ok": True, "result": STATUS},
        "ring_get_health_day": {"ok": True, "result": DAY},
    })
    src = RingSource("phone-1", "r12", invoke=invoke)
    assert (src.kind, src.prefix) == ("ring", "ring_")

    src.identity()
    day = src.fetch_day("2026-09-17", "America/Chicago")
    src.backfill(7)

    assert skills(calls) == ["ring_get_status", "wearables_connect", "ring_sync", "ring_get_health_day",
                             "ring_get_history"]
    assert day.source == "ring"


# ── the roster, the run and the phone's push ────────────────────────────────

X5_ID = "C0FFEE00-1111-2222-3333-444455556666"
R12_ID = "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20"


def test_a_linked_x5_gets_an_x5_source_next_to_the_r12(tmp_registry):
    from jarvis_health.runner import _sources_for

    store = HealthStore()
    store.upsert_device({"kind": "x5ring", "device_id": X5_ID, "bridge_device_id": "phone-1"})
    store.upsert_device({"kind": "ring", "device_id": R12_ID, "bridge_device_id": "phone-1"})

    sources = _sources_for(store)

    assert set(sources) == {"x5ring-c0ffee00", "ring-b6ce93c4"}
    x5_source = sources["x5ring-c0ffee00"]
    assert (x5_source.kind, x5_source.prefix, x5_source.wearable_id) == ("x5ring", "x5_", X5_ID)
    assert sources["ring-b6ce93c4"].prefix == "ring_"


def test_a_scheduled_run_syncs_the_x5_and_files_its_day_under_it(tmp_registry, monkeypatch):
    from jarvis_health import runner
    from jarvis_health.sources import ring

    calls, invoke = recording({"x5_get_health_day": {"ok": True, "result": X5_DAY}})
    monkeypatch.setattr(ring, "bridge_invoke", invoke)
    HealthStore().upsert_device({"kind": "x5ring", "device_id": X5_ID, "bridge_device_id": "phone-1"})

    out = runner.run(call=lambda **kw: "Slept well.", notify=lambda *a: None, now="2026-09-17T17:00:00Z")

    assert "skipped" not in out
    assert "x5_sync" in skills(calls) and not any(s.startswith("ring_") for s in skills(calls))
    stored = HealthStore().day("2026-09-17", "x5ring-c0ffee00")
    assert stored is not None and stored.source == "x5ring"


def test_the_x5_joins_jarvis_health_from_the_phones_roster(tmp_registry, monkeypatch):
    from jarvis_health.bootstrap import ensure_health_integration

    monkeypatch.setattr("jarvis_health.bootstrap.ensure_schedule", lambda *a, **k: None)
    ensure_health_integration([{"kind": "x5ring", "device_id": X5_ID, "name": "X5_1A2B",
                                "bridge_device_id": "phone-1"}])

    roster = HealthStore().roster()
    assert [(d["key"], d["kind"], d["linked"]) for d in roster] == [("x5ring-c0ffee00", "x5ring", True)]


class _Handler:
    status = None
    body = None


def test_a_day_the_phone_pushes_for_the_x5_is_filed_as_the_x5(tmp_registry, monkeypatch):
    import api.health_routes as routes
    import api.helpers as helpers

    def j(handler, body, status=200):
        handler.status, handler.body = status, json.loads(json.dumps(body, default=str))

    monkeypatch.setattr(helpers, "j", j)
    HealthStore().upsert_device({"kind": "x5ring", "device_id": X5_ID})

    handler = _Handler()
    raw = {**X5_DAY, "device_id": X5_ID}
    assert routes.handle_post(handler, urlparse("/api/integrations/jarvis-health/health/day"), {"day": raw})
    assert handler.body["ok"] is True

    stored = HealthStore().day("2026-09-17", "x5ring-c0ffee00")
    assert stored.source == "x5ring"
    assert stored.activity["steps"] == 4200
