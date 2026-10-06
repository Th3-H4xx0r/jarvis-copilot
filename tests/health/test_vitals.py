"""Spot readings: blood pressure, glucose, blood fats, uric acid, body composition, ECG."""
import json
from urllib.parse import urlparse

import pytest

from jarvis_health import vitals
from jarvis_health.history import day_summary, history
from jarvis_health.merge import merged_day
from jarvis_health.sources.ring import day_from_ring_json
from jarvis_health.store import HealthStore
from jarvis_health.window import cycle

from .fixtures import day

NOW = "2026-09-18T20:00:00Z"
BAND, RING = "band-bbbb0000", "ring-aaaa0000"


def reading(type_, time, outcome="done", **fields):
    row = {"type": type_, "time": time, "outcome": outcome}
    extra = {k: v for k, v in fields.items() if k not in ("value", "systolic", "diastolic", "celsius")}
    row.update({k: v for k, v in fields.items() if k in ("value", "systolic", "diastolic", "celsius")})
    if extra:
        row["extra"] = extra
    return row


def glucose(time, mmol):
    return reading("blood_glucose", time, blood_glucose_mmol_l=mmol)


def bp(time, s, d):
    return reading("blood_pressure", time, systolic=s, diastolic=d)


def _store(band_days, ring=True, primary=RING):
    """A ring that leads and a band that only measures; `band_days` = {date: [rows]}."""
    store = HealthStore()
    if ring:
        store.upsert_device({"kind": "ring", "device_id": "aaaa0000"})
    store.upsert_device({"kind": "band", "device_id": "bbbb0000"})
    store.put_settings({"primary_device": primary})
    for date, rows in band_days.items():
        if ring:
            store.put_day(day(date=date), RING)
        d = day(date=date)
        d.measurements = rows
        d.source = "band"
        store.put_day(d, BAND)
    return store


# ── readings ─────────────────────────────────────────────────────────────────

def test_one_blood_component_reading_is_five_values():
    row = reading("blood_component", "2026-09-17T15:00:00Z", uric_acid_umol_l=350, cholesterol_mmol_l=4.6,
                  triglycerides_mmol_l=1.2, hdl_mmol_l=1.4, ldl_mmol_l=2.7)
    got = {r["metric"]: r["value"] for r in vitals.readings([row])}
    assert got == {"uric_acid": 350, "cholesterol": 4.6, "triglycerides": 1.2, "hdl": 1.4, "ldl": 2.7}


def test_only_finished_plausible_readings_count_and_each_once():
    rows = [glucose("2026-09-17T15:00:00Z", 5.4), glucose("2026-09-17T15:00:00Z", 5.4),
            reading("blood_glucose", "2026-09-17T16:00:00Z", outcome="failed", blood_glucose_mmol_l=5.0),
            glucose("2026-09-17T17:00:00Z", 0), glucose("2026-09-17T18:00:00Z", 90),
            bp("2026-09-17T19:00:00Z", 118, 0)]
    assert [(r["metric"], r["value"]) for r in vitals.readings(rows)] == [("blood_glucose", 5.4)]


def test_ecg_carries_heart_rate_hrv_breathing_and_qtc():
    row = reading("ecg", "2026-09-17T15:00:00Z", value=64, hrv=48, respiratory_rate=14, qtc_ms=410)
    got = {r["metric"]: r["value"] for r in vitals.readings([row])}
    assert got == {"ecg": 64, "ecg_hrv": 48, "respiratory_rate": 14, "ecg_qtc": 410}


def test_the_days_own_blood_pressure_history_joins_the_spot_checks():
    raw = {"date": "2026-09-17", "timezone": "America/Chicago",
           "measurements": [bp("2026-09-17T15:00:00Z", 121, 79)],
           "blood_pressure": [{"time": "2026-09-17T12:00:00Z", "systolic": 116, "diastolic": 74},
                              {"time": "2026-09-17T13:00:00Z", "systolic": 0, "diastolic": 74}]}
    day_ = day_from_ring_json(raw, "2026-09-17", "America/Chicago", source="band")
    got = [(r["value"], r["diastolic"]) for r in vitals.readings(day_.measurements)]
    assert got == [(116, 74), (121, 79)]
    assert day_.measurements[0]["auto"] is True


# ── merged and windowed days ─────────────────────────────────────────────────

def test_a_band_that_does_not_lead_still_brings_its_readings(tmp_registry):
    store = _store({"2026-09-17": [glucose("2026-09-17T15:00:00Z", 5.4)]})
    merged = merged_day(store, "2026-09-17")
    assert merged.source == RING
    assert [r["value"] for r in vitals.readings(merged.measurements)] == [5.4]


def test_the_days_window_carries_the_readings_taken_in_it(tmp_registry):
    store = _store({"2026-09-17": [glucose("2026-09-17T15:00:00Z", 5.4)]})
    window = cycle(store, "2026-09-17", NOW)
    assert [m["extra"]["blood_glucose_mmol_l"] for m in window["day"]["measurements"]] == [5.4]
    summary = day_summary(store, "2026-09-17", NOW)
    assert (summary["blood_glucose"], summary["blood_glucose_count"]) == (5.4, 1)


def test_a_weigh_in_wins_over_the_bands_body_fat(tmp_registry):
    store = _store({"2026-09-17": [reading("body_composition", "2026-09-17T15:00:00Z", bmi=24.1,
                                           body_fat_percent=22.0, muscle_mass_kg=55.0)]})
    assert day_summary(store, "2026-09-17", NOW)["body_fat"] == 22.0
    store.upsert_device({"kind": "scale", "device_id": "scale1"})
    store.put_weights([{"id": "w1", "at": "2026-09-17T14:00:00Z", "weight_kg": 72.0, "body_fat": 19.5}], "scale-scale1")
    summary = day_summary(store, "2026-09-17", NOW)
    assert summary["body_fat"] == 19.5 and summary["muscle_mass"] == 55.0


# ── history ──────────────────────────────────────────────────────────────────

def test_glucose_history_buckets_readings_and_says_where_it_sits(tmp_registry):
    store = _store({
        "2026-09-16": [glucose("2026-09-16T15:00:00Z", 5.8), glucose("2026-09-16T23:00:00Z", 6.2)],
        "2026-09-17": [glucose("2026-09-17T15:00:00Z", 6.0)],
    })
    out = history(store, "blood_glucose", "W", "2026-09-18", NOW)
    by_day = {b["start"]: b["value"] for b in out["buckets"] if b["days"]}
    assert by_day == {"2026-09-16": 6.0, "2026-09-17": 6.0}
    assert out["kind"] == "glucose"
    assert "elevated range" in out["highlight"] and "not a diagnosis" in out["highlight"]
    assert [r["value"] for r in out["readings"]] == [6.0, 6.2, 5.8], "newest first"
    readings = next(s for s in out["stats"] if s["label"] == "Readings")
    assert readings["value"] == 3


def test_the_highlight_speaks_the_chosen_unit(tmp_registry):
    store = _store({"2026-09-17": [glucose("2026-09-17T15:00:00Z", 5.0)]})
    store.put_settings({"glucose_unit": "mgdL"})
    assert "90 mg/dL" in history(store, "blood_glucose", "W", "2026-09-18", NOW)["highlight"]


def test_blood_pressure_buckets_run_from_diastolic_to_systolic(tmp_registry):
    store = _store({"2026-09-17": [bp("2026-09-17T15:00:00Z", 120, 80), bp("2026-09-17T18:00:00Z", 130, 84)]})
    out = history(store, "blood_pressure", "W", "2026-09-18", NOW)
    bucket = next(b for b in out["buckets"] if b["days"])
    assert (bucket["value"], bucket["low"]) == (125.0, 82.0)
    assert (out["headline"]["value"], out["headline"]["low"]) == (125.0, 82.0)
    stats = {s["label"]: s["value"] for s in out["stats"]}
    assert stats["Highest systolic"] == 130 and stats["Readings"] == 2
    assert "125/82 mmHg" in out["highlight"] and "high range" in out["highlight"]


def test_every_vital_has_a_history(tmp_registry):
    store = _store({"2026-09-17": []})
    for key in vitals.VITALS:
        out = history(store, key, "M", "2026-09-18", NOW)
        assert out["metric"] == key and len(out["buckets"]) == 30


# ── reference ranges and insights ────────────────────────────────────────────

@pytest.mark.parametrize("key,value,sex,diastolic,status", [
    ("blood_glucose", 5.0, "", None, "normal"),
    ("blood_glucose", 6.1, "", None, "elevated"),
    ("blood_glucose", 7.4, "", None, "high"),
    ("blood_pressure", 115, "", 75, "normal"),
    ("blood_pressure", 124, "", 78, "elevated"),
    ("blood_pressure", 118, "", 82, "high"),
    ("hdl", 1.1, "male", None, "normal"),
    ("hdl", 1.1, "female", None, "low"),
    ("uric_acid", 400, "male", None, "normal"),
    ("uric_acid", 400, "female", None, "high"),
    ("bmi", 23.0, "", None, "normal"),
    ("bmi", 31.0, "", None, "high"),
    ("triglycerides", 1.9, "", None, "elevated"),
    ("cholesterol", 5.0, "", None, "normal"),
])
def test_reference_ranges(key, value, sex, diastolic, status):
    assert vitals.classify(key, value, sex, diastolic)["status"] == status


def test_insights_flag_a_rising_trend_and_say_they_are_estimates(tmp_registry):
    store = _store({
        "2026-09-01": [glucose("2026-09-01T15:00:00Z", 5.0)],
        "2026-09-03": [glucose("2026-09-03T15:00:00Z", 5.1)],
        "2026-09-16": [glucose("2026-09-16T15:00:00Z", 6.0)],
        "2026-09-17": [glucose("2026-09-17T15:00:00Z", 6.2)],
    })
    out = vitals.insights(store, "2026-09-18", days=30)
    g = out["metrics"]["blood_glucose"]
    assert (g["trend"], g["status"], g["count"]) == ("rising", "elevated", 4)
    assert g["latest"]["text"] == "6.2 mmol/L"
    assert "not medical measurements" in out["disclaimer"]
    assert any("rising this week" in line for line in out["insights"])


# ── over HTTP ────────────────────────────────────────────────────────────────

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


BASE = "/api/integrations/jarvis-health/health"


def test_a_pushed_band_day_reaches_the_vitals_endpoint(routes):
    store = _store({}, ring=False, primary=BAND)
    raw = {"date": "2026-09-17", "timezone": "America/Chicago", "source": "band", "device_id": "bbbb0000",
           "measurements": [bp("2026-09-17T15:00:00Z", 128, 81),
                            reading("body_composition", "2026-09-17T15:30:00Z", bmi=24.6, body_fat_percent=21.0)]}
    handler = type("H", (), {"status": None, "body": None})()
    assert routes.handle_post(handler, urlparse(f"{BASE}/day"), {"day": raw})
    assert handler.status == 200
    assert store.day("2026-09-17", BAND) is not None

    got = type("H", (), {"status": None, "body": None})()
    assert routes.handle_get(got, urlparse(f"{BASE}/vitals?days=30&end=2026-09-18"))
    assert got.status == 200
    assert got.body["metrics"]["blood_pressure"]["latest"]["text"] == "128/81 mmHg"
    assert got.body["metrics"]["bmi"]["status"] == "normal"

    hist = type("H", (), {"status": None, "body": None})()
    assert routes.handle_get(hist, urlparse(f"{BASE}/history?metric=blood_pressure&range=W&end=2026-09-18"))
    assert hist.status == 200 and hist.body["readings"][0]["diastolic"] == 81


def test_reference_bars_follow_sex_and_age():
    young_man = vitals.reference("body_fat", "male", 30)[0]["segments"]
    older_woman = vitals.reference("body_fat", "female", 65)[0]["segments"]
    assert [s["from"] for s in young_man][:3] == [3, 8, 20]
    assert [s["from"] for s in older_woman][:3] == [3, 24, 36]
    man = vitals.reference("uric_acid", "male")[0]["segments"]
    woman = vitals.reference("uric_acid", "female")[0]["segments"]
    assert (man[1]["from"], man[1]["to"]) == (200, 420)
    assert (woman[1]["from"], woman[1]["to"]) == (140, 360)


def test_every_bar_is_contiguous_and_in_order():
    for key in list(vitals.VITALS) + ["heart_rate", "spo2", "temperature"]:
        for sex in ("", "male", "female"):
            for age in (None, 25, 50, 70):
                for bar in vitals.reference(key, sex, age):
                    segs = bar["segments"]
                    assert segs, (key, bar)
                    for a, b in zip(segs, segs[1:]):
                        assert a["to"] == b["from"], (key, sex, age)
                    assert all(s["from"] < s["to"] for s in segs), (key, sex, age)


def test_blood_pressure_has_a_diastolic_bar_on_the_bucket_low():
    bars = vitals.reference("blood_pressure")
    assert [b["field"] for b in bars] == ["value", "low"]
