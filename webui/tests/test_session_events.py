"""Per-session event fan-out — the discovery channel for cross-device mirroring.

The run stream itself already fans out correctly; what was missing is a way for a
device to learn that a run STARTED somewhere else, plus the non-run changes
(title, rename, delete) that no stream carries at all.
"""

from __future__ import annotations

import queue
import threading

from api.session_events import SessionEventBus


def _drain(q, limit=50):
    out = []
    for _ in range(limit):
        try:
            out.append(q.get_nowait())
        except queue.Empty:
            break
    return out


def test_every_subscriber_receives_the_event():
    bus = SessionEventBus()
    a = bus.subscribe("s1")
    b = bus.subscribe("s1")

    bus.publish("s1", "run_started", {"stream_id": "abc"})

    assert _drain(a) == [("run_started", {"stream_id": "abc"})]
    assert _drain(b) == [("run_started", {"stream_id": "abc"})]


def test_sessions_are_isolated():
    bus = SessionEventBus()
    mine = bus.subscribe("s1")
    other = bus.subscribe("s2")

    bus.publish("s1", "run_started", {"stream_id": "abc"})

    assert len(_drain(mine)) == 1
    assert _drain(other) == [], "an event leaked into another session's channel"


def test_late_subscriber_gets_the_buffered_tail():
    # The phone starts a run and the laptop opens the chat a moment later: it
    # must still learn the run is in flight rather than sit blank until the end.
    bus = SessionEventBus()
    bus.publish("s1", "run_started", {"stream_id": "abc"})

    late = bus.subscribe("s1")

    assert _drain(late) == [("run_started", {"stream_id": "abc"})]


def test_offline_buffer_is_bounded():
    # STREAMS' buffer is an unbounded list, which is survivable only because a
    # run channel is short-lived. A SESSION channel outlives every run on that
    # session, so an unbounded buffer here is a slow leak.
    bus = SessionEventBus(buffer_size=4)
    for i in range(20):
        bus.publish("s1", "session_changed", {"n": i})

    got = _drain(bus.subscribe("s1"))

    assert len(got) == 4, f"buffer grew past its bound: {len(got)}"
    assert [d["n"] for _, d in got] == [16, 17, 18, 19], "kept the wrong end"


def test_buffer_clears_once_someone_is_listening():
    bus = SessionEventBus(buffer_size=8)
    bus.publish("s1", "session_changed", {"n": 0})
    first = bus.subscribe("s1")
    _drain(first)

    bus.publish("s1", "session_changed", {"n": 1})
    second = bus.subscribe("s1")

    # The live subscriber saw it; the newcomer must not be handed a replay of an
    # event that was already delivered to an attached listener.
    assert [d["n"] for _, d in _drain(first)] == [1]
    assert _drain(second) == []


def test_slow_subscriber_is_dropped_not_grown_without_limit():
    # A stalled SSE writer must not be able to grow its queue forever. The chat
    # queues are unbounded; every other subscriber pool in the codebase is not.
    bus = SessionEventBus(queue_size=4)
    slow = bus.subscribe("s1")

    for i in range(50):
        bus.publish("s1", "session_changed", {"n": i})

    got = _drain(slow, limit=200)
    assert len(got) <= 4, f"slow subscriber queue grew to {len(got)}"


def test_unsubscribe_stops_delivery():
    bus = SessionEventBus()
    q = bus.subscribe("s1")
    bus.unsubscribe("s1", q)

    bus.publish("s1", "run_started", {"stream_id": "abc"})

    assert _drain(q) == []


def test_channel_is_reaped_when_last_subscriber_leaves():
    # Otherwise the bus grows one channel per session id ever opened and never
    # gives the memory back.
    bus = SessionEventBus()
    q = bus.subscribe("s1")
    assert bus.channel_count() == 1

    bus.unsubscribe("s1", q)

    assert bus.channel_count() == 0


def test_publish_to_nobody_is_harmless():
    bus = SessionEventBus()
    bus.publish("nobody-here", "session_changed", {})   # must not raise
    assert bus.channel_count() == 1                      # buffered for a joiner


def test_concurrent_publish_and_subscribe_deliver_every_event():
    # subscribe() must replay the buffer and attach atomically, or a publish
    # landing in between is lost to the new subscriber.
    bus = SessionEventBus(buffer_size=512, queue_size=2048)
    stop = threading.Event()

    def publisher():
        i = 0
        while not stop.is_set():
            bus.publish("s1", "session_changed", {"n": i})
            i += 1

    t = threading.Thread(target=publisher, daemon=True)
    t.start()
    try:
        subs = [bus.subscribe("s1") for _ in range(8)]
    finally:
        stop.set()
        t.join(timeout=2)

    for q in subs:
        got = _drain(q, limit=5000)
        ns = [d["n"] for _, d in got]
        assert ns == sorted(ns), "events arrived out of order"
        assert len(ns) == len(set(ns)), "an event was delivered twice"


# ── wiring: the emit points that make the bus useful ────────────────────────

def test_session_save_announces_a_change(tmp_path, monkeypatch):
    """One hook in Session.save() must cover every handler that mutates state."""
    import api.models as models
    from api.session_events import SESSION_EVENTS

    monkeypatch.setattr(models, "SESSION_DIR", tmp_path)
    s = models.Session(session_id="mirror_probe", title="Before")
    q = SESSION_EVENTS.subscribe("mirror_probe")

    s.title = "After"
    s.save(skip_index=True)

    events = _drain(q)
    assert [e for e, _ in events] == ["session_changed"]
    assert events[0][1]["title"] == "After"
    assert events[0][1]["session_id"] == "mirror_probe"

    SESSION_EVENTS.unsubscribe("mirror_probe", q)


def test_save_still_succeeds_when_the_bus_blows_up(tmp_path, monkeypatch):
    """A mirror announcement must never fail a save that already hit disk."""
    import api.models as models
    import api.session_events as se

    monkeypatch.setattr(models, "SESSION_DIR", tmp_path)

    class _Exploding:
        def publish(self, *a, **kw):
            raise RuntimeError("bus is down")

    monkeypatch.setattr(se, "SESSION_EVENTS", _Exploding())

    s = models.Session(session_id="mirror_probe2", title="T")
    s.save(skip_index=True)                       # must not raise

    assert (tmp_path / "mirror_probe2.json").exists()


def test_snapshot_reports_a_live_run_so_a_late_joiner_can_attach():
    import api.routes as routes
    from api.config import STREAMS, STREAMS_LOCK, STREAM_LAST_EVENT_ID

    sid, stream_id = "snap_probe", "deadbeef"

    class _S:
        session_id = sid
        active_stream_id = stream_id

    routes.SESSIONS[sid] = _S()
    with STREAMS_LOCK:
        STREAMS[stream_id] = object()
    STREAM_LAST_EVENT_ID[stream_id] = f"{stream_id}:42"
    try:
        snap = routes._session_events_snapshot(sid)
        assert snap["active_stream_id"] == stream_id
        assert snap["last_seq"] == 42, "cursor must come back so replay starts in the right place"
    finally:
        routes.SESSIONS.pop(sid, None)
        with STREAMS_LOCK:
            STREAMS.pop(stream_id, None)
        STREAM_LAST_EVENT_ID.pop(stream_id, None)


def test_snapshot_ignores_a_stream_id_whose_worker_is_gone():
    """active_stream_id outlives a dead worker; announcing it sends the client
    chasing a stream that will never produce another event."""
    import api.routes as routes

    sid = "snap_probe_stale"

    class _S:
        session_id = sid
        active_stream_id = "not_in_STREAMS"

    routes.SESSIONS[sid] = _S()
    try:
        assert routes._session_events_snapshot(sid)["active_stream_id"] is None
    finally:
        routes.SESSIONS.pop(sid, None)
