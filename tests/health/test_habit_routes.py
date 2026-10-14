"""Habits in the store and over HTTP: the phone's and chat's one way in."""
import pytest

from jarvis_health.store import HealthStore

from .test_routes import BASE, _get, _post, routes  # noqa: F401 — the fixture

LA = "America/Los_Angeles"


@pytest.fixture
def pushes(monkeypatch):
    sent = []
    monkeypatch.setattr("api.device_bridge.publish",
                        lambda topic, data=None, exclude=None: sent.append((topic, data)) or 0)
    return sent


@pytest.fixture
def store(tmp_registry):
    return HealthStore()


def _habit(**extra):
    return {"id": "scroll", "name": "Doomscrolling", "started_at": "2026-10-01T07:00:00Z", "timezone": LA, **extra}


def test_habits_round_trip_and_deleting_one_takes_its_relapses(store):
    store.put_habit(_habit(goal={"streak_days": 30}))
    assert [h["id"] for h in store.habits()] == ["scroll"]
    assert store.habit("scroll")["goal"] == {"streak_days": 30, "limit": None}
    store.put_relapse("scroll", at="2026-10-05T07:00:00Z", uid="a1")
    store.put_relapse("scroll", at="2026-10-03T07:00:00Z", uid="a2")
    assert [r["uid"] for r in store.relapses("scroll")] == ["a2", "a1"]     # oldest first
    assert store.relapses("scroll")[0] == {"habit": "scroll", "uid": "a2", "at": "2026-10-03T07:00:00Z", "tz": LA}
    assert store.latest_relapse("scroll")["uid"] == "a1"
    assert store.delete_habit("scroll")
    assert store.habits() == [] and store.relapses() == []
    assert not store.delete_habit("scroll")


def test_an_edit_keeps_when_the_habit_was_created(store):
    first = store.put_habit(_habit(), now="2026-10-01T08:00:00Z")
    again = store.put_habit({"id": "scroll", "name": "Scrolling"}, now="2026-10-02T08:00:00Z")
    assert again["created_at"] == first["created_at"] == "2026-10-01T08:00:00Z"
    assert again["started_at"] == "2026-10-01T07:00:00Z"


def test_a_relapse_posted_twice_is_stored_once(store):
    store.put_habit(_habit())
    store.put_relapse("scroll", at="2026-10-05T07:00:00Z", uid="same")
    store.put_relapse("scroll", at="2026-10-05T07:00:00Z", uid="same")
    assert len(store.relapses("scroll")) == 1


def test_the_same_relapse_sent_from_two_threads_at_once_is_stored_once(store):
    import threading

    store.put_habit(_habit())

    def send():
        for i in range(150):
            HealthStore().put_relapse("scroll", at="2026-10-05T07:00:00Z", uid=f"u{i}")

    threads = [threading.Thread(target=send) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(store.relapses("scroll")) == 150


def test_relapses_come_back_past_the_registrys_page(store):
    store.put_habit(_habit())
    for i in range(1005):
        store.put_relapse("scroll", at=f"2026-10-0{1 + i % 9}T07:{i % 60:02d}:{i // 60:02d}Z", uid=f"u{i}")
    got = store.relapses("scroll")
    assert len(got) == 1005 and len({r["uid"] for r in got}) == 1005


def test_relapse_refusals(store):
    with pytest.raises(LookupError):
        store.put_relapse("nope")
    store.put_habit(_habit())
    with pytest.raises(ValueError):
        store.put_relapse("scroll", at="2999-01-01T00:00:00Z")
    with pytest.raises(ValueError):
        store.put_relapse("scroll", at="last tuesday")
    with pytest.raises(ValueError):
        store.put_relapse("scroll", uid="has space")
    assert store.habit("Not An Id") is None


def test_the_routes(routes, pushes):  # noqa: F811
    made = _post(routes, f"{BASE}/habits", {"habit": {"name": "No Instagram", "timezone": LA}})
    assert made.status == 200 and made.body["habit"]["id"].startswith("no-instagram-")
    hid = made.body["habit"]["id"]
    logged = _post(routes, f"{BASE}/habits/relapse", {"habit": hid})
    assert logged.status == 200 and logged.body["summary"]["total"] == 1
    assert logged.body["relapse"]["habit"] == hid
    listed = _get(routes, f"{BASE}/habits").body
    assert listed["habits"][0]["summary"]["total"] == 1 and "relapses" not in listed
    assert len(_get(routes, f"{BASE}/habits?relapses=1").body["relapses"]) == 1
    days = _get(routes, f"{BASE}/habits/days?id={hid}&days=7").body
    assert len(days["days"]) == 7 and days["days"][-1]["count"] == 1
    undone = _post(routes, f"{BASE}/habits/relapse/delete", {"habit": hid, "latest": True})
    assert undone.body["deleted"] is True
    # Nothing left to undo: no change, so nothing is pushed.
    assert _post(routes, f"{BASE}/habits/relapse/delete", {"habit": hid, "latest": True}).body["deleted"] is False
    assert _post(routes, f"{BASE}/habits/delete", {"id": hid}).body["deleted"] is True
    assert pushes == [("habits", {"what": ["habits"]})] * 4


def test_route_refusals(routes, pushes):  # noqa: F811
    assert _post(routes, f"{BASE}/habits", {"habit": {"name": ""}}).status == 400
    assert _post(routes, f"{BASE}/habits", {}).status == 400
    assert _post(routes, f"{BASE}/habits/relapse", {"habit": "missing"}).status == 404
    assert _get(routes, f"{BASE}/habits/days?id=missing").status == 404
    assert _get(routes, f"{BASE}/habits/days?id=x&days=0").status == 400
    assert _post(routes, f"{BASE}/habits/relapse/delete", {}).status == 400
    assert _post(routes, f"{BASE}/habits/sideways", {}).status == 404
    assert pushes == []
