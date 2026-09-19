"""Weight from the phone's scales: stored per reading, shown on the day it was
taken, and charted in history like every other metric."""
import pytest

from jarvis_health.history import history
from jarvis_health.store import HealthStore

from .fixtures import day


@pytest.fixture
def store(tmp_registry):
    s = HealthStore()
    s.upsert_device({"kind": "scale", "device_id": "3c0f01eb-9808-4f89"})
    return s


def _reading(rid, at, kg, fat=None):
    out = {"id": rid, "at": at, "weight_kg": kg, "bmi": round(kg / 1.8 ** 2, 1)}
    if fat is not None:
        out["body_fat"] = fat
    return out


def test_readings_are_kept_once_each(store):
    n = store.put_weights([_reading("a", "2026-09-18T12:05:00Z", 72.4, 18.1)], "scale-3c0f01eb")
    again = store.put_weights([_reading("a", "2026-09-18T12:05:00Z", 72.4, 18.1),
                               _reading("b", "2026-09-19T12:10:00Z", 72.1)], "scale-3c0f01eb")
    assert (n, again) == (1, 2)
    got = store.weights("2026-09-18T00:00:00Z", "2026-09-20T00:00:00Z")
    assert [r["id"] for r in got] == ["a", "b"]
    assert got[0]["body_fat"] == 18.1 and got[0]["device"] == "scale-3c0f01eb"


def test_bad_readings_are_refused(store):
    with pytest.raises(ValueError):
        store.put_weights([{"id": "x", "at": "2026-09-18T12:05:00", "weight_kg": 70}], "scale-3c0f01eb")
    with pytest.raises(ValueError):
        store.put_weights([{"id": "x", "at": "2026-09-18T12:05:00Z", "weight_kg": 4}], "scale-3c0f01eb")


def test_an_unlinked_scale_is_left_out(store):
    store.put_weights([_reading("a", "2026-09-18T12:05:00Z", 72.4)], "scale-3c0f01eb")
    store.set_linked("scale-3c0f01eb", False)
    assert store.weights("2026-09-18T00:00:00Z", "2026-09-20T00:00:00Z") == []


def test_the_latest_reading_before_a_moment(store):
    store.put_weights([_reading("a", "2026-09-10T12:00:00Z", 73.0), _reading("b", "2026-09-18T12:00:00Z", 72.4)],
                      "scale-3c0f01eb")
    assert store.latest_weight("2026-09-15T00:00:00Z")["id"] == "a"
    assert store.latest_weight("2026-09-20T00:00:00Z")["id"] == "b"
    assert store.latest_weight("2026-09-01T00:00:00Z") is None


def test_history_charts_weight_even_before_the_ring(store):
    store.put_day(day(), "ring-aaaa0000")
    for i, kg in enumerate([73.0, 72.8, 72.6]):
        store.put_weights([_reading(f"r{i}", f"2026-09-{15 + i:02d}T12:00:00Z", kg, 18 + i)], "scale-3c0f01eb")
    out = history(store, "weight", "W", "2026-09-17", "2026-09-17T20:00:00Z")
    values = [b["value"] for b in out["buckets"]]
    assert values[-3:] == [73.0, 72.8, 72.6]
    assert out["kind"] == "kg"
    assert out["headline"]["value"] == pytest.approx(72.8)
    fat = history(store, "body_fat", "W", "2026-09-17", "2026-09-17T20:00:00Z")
    assert [b["value"] for b in fat["buckets"]][-3:] == [18, 19, 20]


def test_the_highlight_speaks_pounds_when_asked(store):
    for i, kg in enumerate([73.0, 72.0]):
        store.put_weights([_reading(f"r{i}", f"2026-09-{16 + i:02d}T12:00:00Z", kg)], "scale-3c0f01eb")
    out = history(store, "weight", "W", "2026-09-17", "2026-09-17T20:00:00Z", weight_unit="lb")
    assert "lb" in out["highlight"] or "Jarvis Health has" in out["highlight"]
