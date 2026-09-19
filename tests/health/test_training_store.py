"""Strength training on the server: workouts that carry a log, and the
templates, custom exercises and per-exercise settings the phone keeps here."""
import pytest

from jarvis_health.store import HealthStore


@pytest.fixture
def store(tmp_registry):
    return HealthStore()


def _workout(start, strength=False):
    w = {"sport": 88 if strength else 7, "sport_name": "Strength" if strength else "Run",
         "start": start, "end": start.replace("T10:", "T11:"), "active_seconds": 3600}
    if strength:
        w["strength"] = {"name": "Push Day", "exercises": []}
    return w


def test_kind_keeps_only_strength_workouts(store):
    store.put_workout(_workout("2026-09-19T10:00:00Z", strength=True), "ring-a")
    store.put_workout(_workout("2026-09-19T10:30:00Z"), "ring-a")
    day = ("2026-09-19T00:00:00Z", "2026-09-20T00:00:00Z")
    assert len(store.workouts(*day)) == 2
    assert [w["sport"] for w in store.workouts(*day, kind="strength")] == [88]


def test_a_workout_can_be_deleted(store):
    store.put_workout(_workout("2026-09-19T10:00:00Z"), "ring-a")
    assert store.delete_workout("2026-09-19T10:00:00Z", "ring-a")
    assert store.workouts("2026-09-19T00:00:00Z", "2026-09-20T00:00:00Z") == []
    assert not store.delete_workout("2026-09-19T10:00:00Z", "ring-a")


def test_templates_round_trip_in_their_order(store):
    store.put_template({"id": "b2", "name": "Pull", "order": 1, "exercises": []})
    store.put_template({"id": "a1", "name": "Push", "order": 0, "exercises": []})
    assert [t["name"] for t in store.training()["templates"]] == ["Push", "Pull"]
    store.put_template({"id": "a1", "name": "Push A", "order": 0, "exercises": []})
    assert [t["name"] for t in store.training()["templates"]] == ["Push A", "Pull"]
    assert store.delete_template("a1")
    assert [t["id"] for t in store.training()["templates"]] == ["b2"]
    assert not store.delete_template("a1")


def test_custom_exercises_round_trip(store):
    store.put_exercise({"id": "custom-zercher", "name": "Zercher carry", "kind": "distance_duration"})
    assert store.training()["exercises"] == [{"id": "custom-zercher", "name": "Zercher carry", "kind": "distance_duration"}]
    assert store.delete_exercise("custom-zercher")
    assert store.training()["exercises"] == []


def test_ids_the_registry_cannot_key_are_refused(store):
    with pytest.raises(ValueError):
        store.put_template({"id": "Has Space", "name": "x"})
    with pytest.raises(ValueError):
        store.put_exercise({"id": "UPPER", "name": "x"})
    with pytest.raises(ValueError):
        store.put_template({"name": "no id"})


def test_settings_merge_per_exercise_and_clear(store):
    store.put_training_settings({"Barbell_Squat": {"rest_s": 180}})
    store.put_training_settings({"Barbell_Squat": {"bar_kg": 20}, "Plank": {"kind": "duration"}})
    assert store.training()["settings"] == {"Barbell_Squat": {"rest_s": 180, "bar_kg": 20}, "Plank": {"kind": "duration"}}
    store.put_training_settings({"Plank": None})
    assert store.training()["settings"] == {"Barbell_Squat": {"rest_s": 180, "bar_kg": 20}}


def test_an_empty_space_has_no_training(store):
    assert store.training() == {"templates": [], "exercises": [], "settings": {}}
