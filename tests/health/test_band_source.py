"""The HBand smart band as a health source: the rings' adapter, speaking `band_*` skills."""
import json
from urllib.parse import urlparse

import pytest

from jarvis_health.metrics import STAGE_DEEP, STAGE_LIGHT
from jarvis_health.sources import DAY_KINDS, ELIGIBLE_KINDS, SourceUnreachable, source_for
from jarvis_health.sources.ring import RingSource
from jarvis_health.store import HealthStore

from .test_ring_source import DAY

# A band day carries blood pressure the way the rings' days carry a spot reading:
# a measurement row, kept by the server exactly as the phone sent it.
BP_READING = {"type": "blood_pressure", "time": "2026-09-17T14:02:00Z", "outcome": "done",
              "systolic": 118, "diastolic": 76}
BAND_DAY = {**DAY, "source": "band", "measurements": [BP_READING]}
STATUS = {"name": "HBand_3C9D", "model": "HBand smart band", "firmware_version": "0.9.4",
          "battery_percent": 71, "charging": False}


def recording(answers):
    """An invoke that answers from `answers` and remembers every skill it was asked for."""
    calls = []

    def invoke(device_id, skill, args=None, timeout=30):
        calls.append((device_id, skill, dict(args or {})))
        return answers.get(skill, {"ok": True, "result": {}})

    return calls, invoke


def band(invoke, bridge="phone-1", wearable="hband"):
    return RingSource(bridge, wearable, invoke=invoke, prefix="band_", kind="band", name="Smart band")


def skills(calls):
    return [skill for _, skill, _ in calls]


def test_the_band_is_an_eligible_day_syncing_kind():
    assert "band" in ELIGIBLE_KINDS
    assert "band" in DAY_KINDS


def test_source_for_the_band_is_the_ring_adapter_with_its_own_prefix():
    src = source_for("band", "phone", "band-id")
    assert isinstance(src, RingSource)
    assert (src.kind, src.prefix) == ("band", "band_")
    assert (src.bridge_device_id, src.wearable_id) == ("phone", "band-id")
    # The rings keep their own names.
    assert (source_for("ring", "phone").prefix, source_for("x5ring", "phone").prefix) == ("ring_", "x5_")


def test_a_band_day_is_fetched_with_band_skills_only():
    calls, invoke = recording({
        "wearables_connect": {"ok": True, "result": {"connected": True}},
        "band_sync": {"ok": True, "result": {"updated": ["sleep"]}},
        "band_get_health_day": {"ok": True, "result": BAND_DAY},
    })
    day = band(invoke).fetch_day("2026-09-17", "America/Chicago")

    assert skills(calls) == ["wearables_connect", "band_sync", "band_get_health_day"]
    assert all(device == "phone-1" for device, _, _ in calls), "skills run on the phone"
    assert calls[0][2] == {"wearable_id": "hband"}, "the hub is told which band to bring up"
    assert calls[2][2] == {"date": "2026-09-17"}
    # Same stage codes as the rings: 3 deep, 2 light.
    assert day.main_sleep.stage_minutes(STAGE_DEEP) == 68
    assert day.main_sleep.stage_minutes(STAGE_LIGHT) == 273
    assert day.activity["steps"] == 4200
    assert day.source == "band"
    assert day.measurements == [BP_READING], "blood pressure comes through untouched"


def test_a_band_day_without_a_date_lets_the_phone_choose_it():
    calls, invoke = recording({"band_get_health_day": {"ok": True, "result": BAND_DAY}})
    day = band(invoke).fetch_day(None, "UTC")
    assert ("phone-1", "band_get_health_day", {}) in calls
    assert (day.date, day.timezone) == ("2026-09-17", "America/Chicago")


def test_an_unreachable_band_is_unreachable_not_an_empty_day():
    calls, invoke = recording({
        "wearables_connect": {"ok": False, "error": "not connected"},
        "band_sync": {"ok": False, "error": "band is not connected over Bluetooth"},
    })
    with pytest.raises(SourceUnreachable, match="not connected over Bluetooth"):
        band(invoke).fetch_day("2026-09-17", "America/Chicago")
    assert "band_get_health_day" not in skills(calls)


def test_band_identity_and_battery_read_band_status():
    calls, invoke = recording({"band_get_status": {"ok": True, "result": STATUS}})
    src = band(invoke)

    ident = src.identity()
    assert ident["kind"] == "band"
    assert ident["device_id"] == "hband"
    assert ident["bridge_device_id"] == "phone-1"
    assert (ident["name"], ident["model"], ident["firmware"]) == ("HBand_3C9D", "HBand smart band", "0.9.4")
    assert src.battery() == {"percent": 71, "charging": False}
    assert skills(calls) == ["band_get_status", "band_get_status"]


def test_a_band_that_says_nothing_is_still_called_a_smart_band():
    _, invoke = recording({"band_get_status": {"ok": False, "error": "phone asleep"}})
    src = source_for("band", "phone", "hband")
    src._invoke = invoke
    assert src.identity()["name"] == "Smart band"
    assert RingSource("phone", invoke=invoke).identity()["name"] == "Ring", "the rings keep theirs"


def test_band_backfill_reads_band_history_and_files_days_as_the_band():
    calls, invoke = recording({"band_get_history": {"ok": True, "result": {"days": [
        {"date": "2026-09-16", "timezone": "America/Chicago", "summary": {"steps": 812, "heart_rate_min": 51}},
        {"summary": {"steps": 1}},  # no date: nothing to file it under
    ]}}})
    days = band(invoke).backfill(45)

    assert skills(calls) == ["band_get_history"]
    assert calls[0][2]["days"] <= 30
    assert [(d.date, d.source, d.activity) for d in days] == [("2026-09-16", "band", {"steps": 812})]


# ── the roster, the run, the merge and the phone's push ─────────────────────

BAND_ID = "C0FFEE00-1111-2222-3333-444455556666"
R12_ID = "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20"
BAND_KEY = "band-c0ffee00"
R12_KEY = "ring-b6ce93c4"


def test_a_linked_band_gets_a_band_source_next_to_the_r12(tmp_registry):
    from jarvis_health.runner import _sources_for

    store = HealthStore()
    store.upsert_device({"kind": "band", "device_id": BAND_ID, "bridge_device_id": "phone-1"})
    store.upsert_device({"kind": "ring", "device_id": R12_ID, "bridge_device_id": "phone-1"})

    sources = _sources_for(store)

    assert set(sources) == {BAND_KEY, R12_KEY}
    band_source = sources[BAND_KEY]
    assert (band_source.kind, band_source.prefix, band_source.wearable_id) == ("band", "band_", BAND_ID)
    assert sources[R12_KEY].prefix == "ring_"


def test_a_scheduled_run_syncs_the_band_and_files_its_day_under_it(tmp_registry, monkeypatch):
    from jarvis_health import runner
    from jarvis_health.sources import ring

    calls, invoke = recording({"band_get_health_day": {"ok": True, "result": BAND_DAY}})
    monkeypatch.setattr(ring, "bridge_invoke", invoke)
    HealthStore().upsert_device({"kind": "band", "device_id": BAND_ID, "bridge_device_id": "phone-1"})

    out = runner.run(call=lambda **kw: "Slept well.", notify=lambda *a: None, now="2026-09-17T17:00:00Z")

    assert "skipped" not in out
    assert "band_sync" in skills(calls) and not any(s.startswith(("ring_", "x5_")) for s in skills(calls))
    stored = HealthStore().day("2026-09-17", BAND_KEY)
    assert stored is not None and stored.source == "band"
    assert stored.measurements == [BP_READING]


def test_the_band_joins_jarvis_health_from_the_phones_roster(tmp_registry, monkeypatch):
    from jarvis_health.bootstrap import ensure_health_integration

    monkeypatch.setattr("jarvis_health.bootstrap.ensure_schedule", lambda *a, **k: None)
    ensure_health_integration([{"kind": "band", "device_id": BAND_ID, "name": "HBand_3C9D",
                                "bridge_device_id": "phone-1"}])

    roster = HealthStore().roster()
    assert [(d["key"], d["kind"], d["linked"], d["name"]) for d in roster] == [
        (BAND_KEY, "band", True, "HBand_3C9D")]


def test_a_band_the_phone_gives_no_name_is_a_smart_band(tmp_registry, monkeypatch):
    from jarvis_health.bootstrap import ensure_health_integration

    monkeypatch.setattr("jarvis_health.bootstrap.ensure_schedule", lambda *a, **k: None)
    ensure_health_integration([{"kind": "band", "device_id": BAND_ID, "bridge_device_id": "phone-1"}])

    assert HealthStore().roster()[0]["name"] == "Smart band"


class _Handler:
    status = None
    body = None


def test_a_day_the_phone_pushes_for_the_band_is_filed_as_the_band(tmp_registry, monkeypatch):
    import api.health_routes as routes
    import api.helpers as helpers

    def j(handler, body, status=200):
        handler.status, handler.body = status, json.loads(json.dumps(body, default=str))

    monkeypatch.setattr(helpers, "j", j)
    HealthStore().upsert_device({"kind": "band", "device_id": BAND_ID})

    handler = _Handler()
    raw = {**BAND_DAY, "device_id": BAND_ID}
    assert routes.handle_post(handler, urlparse("/api/integrations/jarvis-health/health/day"), {"day": raw})
    assert handler.body["ok"] is True

    stored = HealthStore().day("2026-09-17", BAND_KEY)
    assert stored.source == "band"
    assert stored.activity["steps"] == 4200
    assert stored.measurements == [BP_READING]


def test_registration_links_only_the_chosen_wearable_and_makes_it_primary(tmp_registry, monkeypatch):
    """The phone registers the ring and the band and says which one Jarvis Health uses."""
    from jarvis_health.bootstrap import ensure_health_integration
    from jarvis_health.store import SHARED_SPACE, device_key_for

    monkeypatch.setattr("jarvis_health.bootstrap.ensure_schedule", lambda *a, **k: None)
    roster = [
        {"kind": "ring", "device_id": "r12-0001", "name": "R12", "bridge_device_id": "phone", "linked": False},
        {"kind": "band", "device_id": "band-0002", "name": "Band", "bridge_device_id": "phone", "linked": True,
         "primary": True},
    ]
    ensure_health_integration(roster)
    store = HealthStore(SHARED_SPACE)
    linked = {d["key"]: d.get("linked") for d in store.roster()}
    assert linked[device_key_for("ring", "r12-0001")] is False
    assert linked[device_key_for("band", "band-0002")] is True
    assert store.settings().get("primary_device") == device_key_for("band", "band-0002")

    # Switching back flips both.
    roster[0].update(linked=True, primary=True)
    roster[1].update(linked=False, primary=False)
    ensure_health_integration(roster)
    linked = {d["key"]: d.get("linked") for d in store.roster()}
    assert linked[device_key_for("ring", "r12-0001")] is True
    assert linked[device_key_for("band", "band-0002")] is False
    assert store.settings().get("primary_device") == device_key_for("ring", "r12-0001")


def test_a_primary_band_supplies_the_day_and_a_ring_only_fills_its_gaps(tmp_registry):
    from jarvis_health.merge import merged_day

    from .fixtures import day as made_day

    store = HealthStore()
    store.upsert_device({"kind": "band", "device_id": BAND_ID})
    store.upsert_device({"kind": "ring", "device_id": R12_ID})
    store.put_settings({"primary_device": BAND_KEY})
    band_day = made_day(asleep=0, hr=[0] * 60 + [64] * 112, steps=3000)  # off the wrist overnight
    ring_day = made_day(hr=[0] * 60 + [90] * 112, steps=9000)
    store.put_day(band_day, BAND_KEY)
    store.put_day(ring_day, R12_KEY)

    merged = merged_day(store, "2026-09-17")

    assert merged.source == BAND_KEY
    assert max(merged.heart_rate.values) == 64, "the primary band's heart, not the ring's"
    assert merged.sleep and merged.main_sleep.asleep_minutes == ring_day.main_sleep.asleep_minutes, \
        "the ring fills in the night the band missed"
    assert merged.activity["steps"] == 9000, "steps take the highest count"


def test_a_low_band_battery_is_called_the_band():
    from jarvis_health.rules import DEFAULT_RULES, evaluate
    from jarvis_health.scoring import Score

    from .fixtures import day as made_day, ready_baseline

    settings = {"rules": DEFAULT_RULES, "quiet_hours": {"start": "22:00", "end": "08:00"}}
    scores = {"health": Score(80), "sleep": Score(80)}

    def battery_message(source):
        d = made_day()
        d.battery, d.source = {"percent": 9, "charging": False}, source
        alerts = evaluate(d, scores, ready_baseline(), settings, "2026-09-17T17:00:00Z", set())
        return next(a.message for a in alerts if a.rule == "battery_low")

    assert battery_message(BAND_KEY) == "Band battery at 9%."
    assert battery_message(R12_KEY) == "Ring battery at 9%."
    assert battery_message("x5ring-0a0b0c0d") == "Ring battery at 9%."
