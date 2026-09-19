"""Outdoor workouts' routes: one document beside each workout, validated,
fetched by the workout's start and filed device, and deleted with it."""
import pytest

from jarvis_health.store import MAX_ROUTE_POINTS, HealthStore

from .test_routes import BASE, _get, _post, routes  # noqa: F401 — the fixture

START = "2026-09-19T13:00:00Z"


def _route(points=3):
    seg = [[i * 2.0, 30.26 + i * 0.0001, -97.75, 150.0 + i, 140 if i % 2 else None, 3.1] for i in range(points)]
    return {"version": 1, "start": START, "segments": [seg[: points // 2 or 1], seg[points // 2 or 1:]],
            "elevation_source": "barometer"}


@pytest.fixture
def store(tmp_registry):
    return HealthStore()


def test_a_route_is_kept_beside_its_workout(store):
    stored = store.put_route(START, "ring-b6ce93c4", _route(10))
    assert stored == {"key": "route-ring-b6ce93c4-20260919130000", "points": 10}
    back = store.route(START, "ring-b6ce93c4")
    assert back["segments"][0][0][:3] == [0.0, 30.26, -97.75]
    assert back["elevation_source"] == "barometer"
    assert store.route(START, "ring-00000000") is None


def test_malformed_routes_are_refused(store):
    for bad in ({}, {"segments": "x"}, {"segments": [[["a", 1, 2]]]}, {"segments": [[[1, 95, 0]]]},
                {"segments": [[[1, 30, -97, "high"]]]}, {"segments": [[[1, 30]]]}):
        with pytest.raises(ValueError):
            store.put_route(START, "ring-b6ce93c4", bad)
    too_many = {"segments": [[[i, 30.0, -97.0] for i in range(MAX_ROUTE_POINTS + 1)]]}
    with pytest.raises(ValueError):
        store.put_route(START, "ring-b6ce93c4", too_many)


def test_deleting_the_workout_deletes_its_route(store):
    store.put_workout({"sport": 7, "sport_name": "Run", "start": START, "end": "2026-09-19T13:30:00Z"}, "ring-b6ce93c4")
    store.put_route(START, "ring-b6ce93c4", _route())
    assert store.delete_workout(START, "ring-b6ce93c4")
    assert store.route(START, "ring-b6ce93c4") is None


def test_the_route_endpoints(routes):  # noqa: F811
    workout = {"sport": 7, "sport_name": "Run", "start": START, "end": "2026-09-19T13:30:00Z",
               "route_summary": {"distance_m": 5012.0, "moving_s": 1580, "preview": "_p~iF~ps|U", "bounds": [1, 2, 3, 4]}}
    saved = _post(routes, f"{BASE}/workouts", {"workout": workout, "device_id": "b6ce93c4-aaaa"}).body["workout"]
    assert saved["route_summary"]["distance_m"] == 5012.0
    posted = _post(routes, f"{BASE}/workouts/route", {"start": START, "device_id": "b6ce93c4-aaaa", "route": _route(6)})
    assert posted.status == 200 and posted.body["points"] == 6
    got = _get(routes, f"{BASE}/workouts/route?start={START}&device={saved['device']}")
    assert got.status == 200 and len(got.body["route"]["segments"]) == 2
    by_id = _get(routes, f"{BASE}/workouts/route?start={START}&device_id=b6ce93c4-aaaa")
    assert by_id.status == 200
    assert _get(routes, f"{BASE}/workouts/route?start=2026-09-19T14:00:00Z&device=ring-b6ce93c4").status == 404
    assert _get(routes, f"{BASE}/workouts/route?start=yesterday").status == 400
    assert _post(routes, f"{BASE}/workouts/route", {"start": START, "route": {"segments": 1}}).status == 400
    # The day carries the summary, never the route.
    day = _get(routes, f"{BASE}/workouts").body["workouts"][0]
    assert "segments" not in day and day["route_summary"]["moving_s"] == 1580
