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


def test_a_run_pointer_is_never_replayed_to_a_later_subscriber():
    """The bug this cost us: opening an old chat re-running its last turn.

    A run_started held while nobody was watching points at a stream that has
    since ended. Replay it to whoever opens the chat next and the client attaches
    to a dead stream_id; the server finds no live channel, falls back to the
    on-disk journal, and replays the FINISHED turn from seq 0 -- so the answer
    that is already in the transcript streams in again underneath it.

    Catching up is the snapshot's job, and unlike a buffer it checks the stream
    is still registered.
    """
    bus = SessionEventBus()
    bus.publish("s1", "run_started", {"stream_id": "long_gone"})

    late = bus.subscribe("s1")

    assert _drain(late) == [], "a stale run pointer was replayed to a new subscriber"


def test_publishing_to_nobody_does_not_create_a_channel():
    # Session.save() announces on EVERY save, so creating a channel here would
    # leave one per session id ever touched, forever, with nobody listening.
    bus = SessionEventBus()
    bus.publish("never-watched", "session_changed", {})
    assert bus.channel_count() == 0


def test_slow_subscriber_is_dropped_not_grown_without_limit():
    # A stalled SSE writer must not be able to grow its queue forever. The chat
    # queues are unbounded; every other subscriber pool in the codebase is not.
    bus = SessionEventBus(queue_size=4)
    slow = bus.subscribe("s1")

    for i in range(50):
        bus.publish("s1", "session_changed", {"n": i})

    got = _drain(slow, limit=200)
    assert len(got) <= 4, f"slow subscriber queue grew to {len(got)}"


def test_a_dropped_event_tells_the_client_to_resync():
    # Silently dropping means that device misses a whole turn while still looking
    # perfectly connected -- the "it just doesn't work sometimes" failure.
    bus = SessionEventBus(queue_size=2)
    slow = bus.subscribe("s1")

    for i in range(20):
        bus.publish("s1", "session_changed", {"n": i})

    assert any(e == "resync" for e, _ in _drain(slow, limit=50)), \
        "a client that fell behind was never told to re-read the session"


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


def test_concurrent_publish_and_subscribe_deliver_every_event():
    # subscribe() must replay the buffer and attach atomically, or a publish
    # landing in between is lost to the new subscriber.
    bus = SessionEventBus(queue_size=8192)
    stop = threading.Event()

    def publisher():
        i = 0
        while not stop.is_set():
            bus.publish("s1", "session_changed", {"n": i})
            i += 1

    subs = [bus.subscribe("s1")]          # one early, so publishes have a target
    t = threading.Thread(target=publisher, daemon=True)
    t.start()
    try:
        subs += [bus.subscribe("s1") for _ in range(8)]
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


def test_endpoint_subscribes_then_snapshots_then_streams(monkeypatch):
    """End to end through the real route: subscribe, snapshot, live frame, cleanup.

    Ordering is the thing under test. The handler subscribes BEFORE sending its
    snapshot, so a run starting in that window is delivered as an event instead
    of falling into the gap between the two.
    """
    import threading
    import time
    from urllib.parse import urlparse
    from api.routes import handle_get
    from api.session_events import SESSION_EVENTS

    sid = "e2e_events_probe"
    frames: list[bytes] = []

    class _H:
        def __init__(self):
            self.wfile = self

        def send_response(self, _status):
            pass

        def send_header(self, *_a):
            pass

        def end_headers(self):
            pass

        def write(self, data):
            frames.append(bytes(data))
            if b"run_started" in bytes(data):
                raise BrokenPipeError("client went away")   # ends the SSE loop

        def flush(self):
            pass

    parsed = urlparse(f"http://x/api/session/events?session_id={sid}")
    t = threading.Thread(target=handle_get, args=(_H(), parsed), daemon=True)
    t.start()

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and SESSION_EVENTS.subscriber_count(sid) == 0:
        time.sleep(0.01)
    assert SESSION_EVENTS.subscriber_count(sid) == 1, "handler never subscribed"

    SESSION_EVENTS.publish(sid, "run_started", {"stream_id": "abc123"})
    t.join(timeout=5)
    assert not t.is_alive(), "handler did not exit on client disconnect"

    blob = b"".join(frames).decode("utf-8", "replace")
    assert "snapshot" in blob, "no snapshot frame — a mid-run joiner would never attach"
    assert "run_started" in blob
    assert "abc123" in blob, "the stream_id must reach the client or it cannot attach"

    assert SESSION_EVENTS.subscriber_count(sid) == 0, "disconnect leaked a subscriber"


def test_endpoint_rejects_a_missing_session_id():
    from urllib.parse import urlparse
    from api.routes import handle_get

    class _H:
        def __init__(self):
            self.status = None
            self.wfile = self
            self.body = bytearray()

        def send_response(self, status):
            self.status = status

        def send_header(self, *_a):
            pass

        def end_headers(self):
            pass

        def write(self, data):
            self.body.extend(data)

        def flush(self):
            pass

    h = _H()
    handle_get(h, urlparse("http://x/api/session/events"))
    assert h.status == 400
