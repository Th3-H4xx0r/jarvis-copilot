"""Topics on the device bridge: the phone subscribes, the server pushes changes coalesced to the
interval it asked for, instead of the phone polling (the battery drain of 2026-10-13)."""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from api import device_bridge as db  # noqa: E402


class _FakeSock:
    def shutdown(self, *_a):
        pass

    def close(self):
        pass


@pytest.fixture
def sent(monkeypatch):
    frames = []
    monkeypatch.setattr(db, "_ws_send_text", lambda conn, text: frames.append((conn.device_id, json.loads(text))))
    return frames


@pytest.fixture
def conns():
    made = []

    def make(device_id, topics=None):
        conn = db._DeviceConn(device_id=device_id, sock=_FakeSock(), conn=None, name="phone")
        db._register(conn)
        made.append(conn)
        if topics is not None:
            db._handle_message(conn, {"type": "subscribe", "topics": topics})
        return conn

    yield make
    for conn in made:
        db._safe_close(conn)
        db._unregister(conn.device_id, conn)


def _topic_frames(frames, device_id=None):
    return [f for d, f in frames if f.get("type") == "topic" and (device_id is None or d == device_id)]


def test_subscribe_replaces_the_set(sent, conns):
    conn = conns("phone-a", {"pods": 0, "dashcam": 0})
    db._handle_message(conn, {"type": "subscribe", "topics": {"widgets": 1800}})
    assert conn.topics == {"widgets": 1800.0}
    assert db.subscribers("pods") == []
    assert db.subscribers("widgets") == ["phone-a"]


def test_bad_subscriptions_are_cleaned(sent, conns):
    conn = conns("phone-b", {"ok": "5", "": 1, "x" * 40: 1, "neg": -3, "huge": 10**9, "nan": "nan", "junk": None})
    assert conn.topics == {"ok": 5.0, "neg": 0.0, "huge": 86400.0, "nan": 0.0, "junk": 0.0}


def test_publish_reaches_only_subscribers(sent, conns):
    conns("phone-c", {"pods": 0})
    conns("mac-c", {})
    assert db.publish("pods", {"statuses": {"p1": {"rssi": -50}}}) == 1
    assert db.publish("dashcam", {"what": ["clips"]}) == 0
    assert _topic_frames(sent) == [{"type": "topic", "topic": "pods", "data": {"statuses": {"p1": {"rssi": -50}}}}]


def test_interval_zero_sends_every_change(sent, conns):
    conns("phone-d", {"dashcam": 0})
    db.publish("dashcam", {"what": ["clips"]})
    db.publish("dashcam", {"what": ["destinations"]})
    assert [f["data"] for f in _topic_frames(sent)] == [{"what": ["clips"]}, {"what": ["destinations"]}]


def test_changes_inside_the_interval_merge_into_one_trailing_frame(sent, conns):
    conn = conns("phone-e", {"widgets": 0.3})
    db.publish("widgets", {"what": ["health"]})
    db.publish("widgets", {"what": ["chats"]})
    db.publish("widgets", {"what": ["health", "coding"]})
    assert [f["data"] for f in _topic_frames(sent)] == [{"what": ["health"]}]
    deadline = time.time() + 2
    while len(_topic_frames(sent)) < 2 and time.time() < deadline:
        time.sleep(0.02)
    assert [f["data"] for f in _topic_frames(sent)] == [{"what": ["health"]}, {"what": ["chats", "health", "coding"]}]
    assert conn.topic_pending == {}


def test_unsubscribing_drops_what_was_held(sent, conns):
    conn = conns("phone-f", {"widgets": 60})
    db.publish("widgets", {"what": ["health"]})
    db.publish("widgets", {"what": ["chats"]})
    assert "widgets" in conn.topic_timers
    db._handle_message(conn, {"type": "subscribe", "topics": {}})
    assert conn.topic_timers == {} and conn.topic_pending == {}


def test_the_device_that_caused_a_change_is_not_told(sent, conns):
    conns("phone-g", {"dashcam": 0})
    conns("ipad-g", {"dashcam": 0})
    assert db.publish("dashcam", {"what": ["destinations"]}, exclude="phone-g") == 1
    assert [d for d, f in sent if f.get("type") == "topic"] == ["ipad-g"]


def test_subscribe_hooks_hear_the_new_set(sent, conns):
    heard = []
    hook = lambda device_id, topics: heard.append((device_id, topics))  # noqa: E731
    db.on_subscribe(hook)
    try:
        conns("phone-h", {"pods": 0})
    finally:
        db._TOPIC_HOOKS.remove(hook)
    assert heard == [("phone-h", {"pods": 0.0})]


def test_wearables_state_is_cached_not_dispatched(sent, conns):
    conn = conns("phone-i")
    rows = [{"device_id": "r1", "model": "R12", "name": "Ring", "connected": True}, "junk"]
    db._handle_message(conn, {"type": "event", "name": "wearables_state", "data": {"wearables": rows}})
    cached = db.wearables_for("phone-i")
    assert cached is not None and cached[0] == [rows[0]]
    db._WEARABLES.pop("phone-i", None)


def test_ping_interval_reads_the_env(monkeypatch):
    monkeypatch.setenv("JC_BRIDGE_PING_S", "30")
    assert db._ping_interval() == 30.0
    monkeypatch.setenv("JC_BRIDGE_PING_S", "1")
    assert db._ping_interval() == 5.0
    monkeypatch.setenv("JC_BRIDGE_PING_S", "soon")
    assert db._ping_interval() == 40.0
    monkeypatch.delenv("JC_BRIDGE_PING_S")
    assert db._ping_interval() == 40.0
