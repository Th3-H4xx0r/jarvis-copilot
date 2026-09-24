"""Live on a server speech engine: the lane that actually transcribes.

With `speech.surfaces.live` set to a streaming engine the server hears the
device's audio itself; the rows, frames and translations are the same ones the
edge lane produces, so viewers, watchers and memory cannot tell the difference
except for who did the hearing.
"""
import base64
import json
import queue
import time

import pytest
import yaml

from api import live_speech, live_store, live_ws
from jarvis_speech.types import Segment
from tests.test_live_ws import (  # noqa: F401 — fixtures are used by name
    _connect, _edge_caps, _post, isolated_state, no_identification,
    no_watcher_threads_left_running, stubbed_watchers)


class FakeLiveStream:
    def __init__(self, sink, final=None):
        self.sink, self.fed, self._final = sink, [], final
        self.finished, self.closed, self.done = 0, False, False
        self.order = None

    def feed(self, pcm, ts_ms=None):
        if self.done:
            return False
        self.fed.append((pcm, ts_ms))
        return True

    def finish(self, timeout=5.0):
        # Like a real stream: the last line is stored before finish() returns.
        if self._final and not self.done:
            self.sink.on_segment(self._final)
        self.done = True
        if self.order is not None:
            self.order.append("finish")
        self.finished += 1
        return []

    def close(self):
        self.closed = self.done = True


class FakeLiveEngine:
    name, label, streams = "fake", "Fake", True

    def __init__(self, final=None):
        self.streams_opened, self.options, self._final = [], [], final

    def open_stream(self, sink, *, rate, translate_to="", purpose="live", idle_close_s=0):
        stream = FakeLiveStream(sink, self._final)
        self.streams_opened.append(stream)
        self.options.append({"rate": rate, "translate_to": translate_to, "purpose": purpose,
                             "idle_close_s": idle_close_s})
        return stream


@pytest.fixture
def engine(monkeypatch):
    fake = FakeLiveEngine()
    monkeypatch.setattr(live_speech, "live_engine", lambda: fake)
    return fake


def _pcm_caps(**over):
    return _edge_caps(codec="pcm16", rate=16000, **over)


def _audio(conn, ts_ms=1500, n=320, seq=1):
    pcm = b"\x01\x00" * n
    conn.on_binary(live_ws.encode_audio_frame(seq, ts_ms, pcm))
    return pcm


def _rows(sid):
    return live_store.segments_after(sid, 0)


def _drain(q, timeout=0.5):
    events, deadline = [], time.time() + timeout
    while time.time() < deadline:
        try:
            events.append(q.get(timeout=0.05))
        except queue.Empty:
            if events:
                break
    return events


def test_live_unavailable_engine_keeps_edge(isolated_state, monkeypatch):
    (isolated_state / "config.yaml").write_text(yaml.safe_dump({"speech": {"surfaces": {"live": "soniox"}}}))
    monkeypatch.setattr("jarvis_speech.keys.soniox_key", lambda: "")
    _conn, client = _connect()
    ready = client.first("ready")
    assert ready["lane"] == live_ws.LANE_EDGE and "engine" not in ready


def test_engine_lane_overrides_on_device(engine):
    _conn, client = _connect()
    ready = client.first("ready")
    assert ready["lane"] == live_ws.LANE_SERVER and ready["engine"] == "Fake"


def test_binary_audio_feeds_the_stream_decoded(engine):
    conn, _client = _connect(caps=_pcm_caps())
    pcm = _audio(conn, ts_ms=1500)
    assert engine.streams_opened[0].fed == [(pcm, 1500)]
    assert engine.options[0]["purpose"] == "live" and engine.options[0]["rate"] == 16000


def test_stream_is_opened_with_quiet_close_and_translation(engine):
    from api import live_config
    live_config.save({"translate": True, "primary_language": "en"})
    conn, _client = _connect(caps=_pcm_caps())
    _audio(conn)
    assert engine.options[0]["translate_to"] == "en"
    assert engine.options[0]["idle_close_s"] == 60


def test_partials_fan_out_to_every_viewer(engine):
    conn, client = _connect(caps=_pcm_caps())
    sid = conn.live_session_id
    q = live_ws.subscribe(sid)
    try:
        _audio(conn)
        sink = engine.streams_opened[0].sink
        sink.on_partial("hola que", 1500, "1", "es")
        sink.on_partial("hola que tal", 1500, "1", "es")  # inside the throttle window
        partials = [data for event, data in _drain(q) if event == "partial"]
    finally:
        live_ws.unsubscribe(sid, q)
    assert len(partials) == 1
    assert partials[0]["text"] == "hola que" and partials[0]["device_id"] == "iphone-17pm"
    conn.on_bus_event("partial", partials[0])
    assert client.first("partial")["text"] == "hola que"


def test_segments_land_with_engine_flags(engine, monkeypatch):
    rescued = []
    monkeypatch.setattr(live_ws, "_rescue_language_async", lambda row, **kw: rescued.append(row) or False)
    conn, _client = _connect(caps=_pcm_caps())
    sid = conn.live_session_id
    q = live_ws.subscribe(sid)
    try:
        _audio(conn)
        engine.streams_opened[0].sink.on_segment(Segment("hola", 100, 900, "es", "hello", "1", key=1))
        events = _drain(q)
    finally:
        live_ws.unsubscribe(sid, q)
    rows = _rows(sid)
    assert [(r["text"], r["lang"], r["translation"], r["device_id"]) for r in rows] == [
        ("hola", "es", "hello", "iphone-17pm")]
    assert rows[0]["local_label"].startswith("fake:") and rows[0]["local_label"].endswith(":1")
    assert rescued == []
    assert any(e == "insight" and d.get("kind") == "translation" and d["seq"] == rows[0]["seq"]
               for e, d in events)


def test_late_translation_updates_the_row(engine):
    conn, _client = _connect(caps=_pcm_caps())
    _audio(conn)
    sink = engine.streams_opened[0].sink
    sink.on_segment(Segment("hola", 100, 900, "es", "", "1", key=7))
    sink.on_translation(7, "hello there")
    assert _rows(conn.live_session_id)[0]["translation"] == "hello there"


def test_short_line_inherits_label_speaker(engine):
    conn, _client = _connect(caps=_pcm_caps())
    sid = conn.live_session_id
    _audio(conn)
    sink = engine.streams_opened[0].sink
    sink.on_segment(Segment("a long first line of speech", 0, 5000, "en", "", "1", key=1))
    first = _rows(sid)[0]
    speaker = live_store.create_speaker(kind="other", name="Sam")
    live_store.assign_speaker(sid, first["seq"], speaker["id"])
    sink.on_segment(Segment("yes", 5200, 6000, "en", "", "1", key=2))
    assert _rows(sid)[1]["speaker_id"] == speaker["id"]


def test_end_finishes_stream_before_session_ends(engine, monkeypatch):
    order = []
    real_end = live_ws.end_live_session
    monkeypatch.setattr(live_ws, "end_live_session", lambda sid: order.append("end") or real_end(sid))
    conn, _client = _connect(caps=_pcm_caps())
    _audio(conn)
    engine.streams_opened[0].order = order
    conn.on_text(json.dumps({"t": "end"}))
    assert order == ["finish", "end"]


def _wait(predicate, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline and not predicate():
        time.sleep(0.02)
    return predicate()


def test_live_reconnect_finishes_old_stream_once(monkeypatch):
    fake = FakeLiveEngine(final=Segment("last words", 100, 900, "en", "", "1", key=1))
    monkeypatch.setattr(live_speech, "live_engine", lambda: fake)
    conn1, _ = _connect(caps=_pcm_caps())
    sid = conn1.live_session_id
    _audio(conn1)
    conn1.close()
    assert _wait(lambda: fake.streams_opened[0].finished == 1)
    conn2, _ = _connect(caps=_pcm_caps(), resume={"live_session_id": sid, "after_seq": 0})
    _audio(conn2, ts_ms=4000, seq=2)   # the phone's count carries on across a reconnect
    assert len(fake.streams_opened) == 2 and fake.streams_opened[1].fed
    assert [r["text"] for r in _rows(sid)] == ["last words"]
    assert fake.streams_opened[0].finished == 1


def test_live_two_devices_two_streams(engine):
    phone, _ = _connect(caps=_pcm_caps())
    sid = phone.live_session_id
    watch, _ = _connect(caps=_pcm_caps(), device_id="watch-9",
                        resume={"live_session_id": sid, "after_seq": 0})
    _audio(phone)
    _audio(watch)
    assert len(engine.streams_opened) == 2
    engine.streams_opened[0].sink.on_segment(Segment("from the phone", 0, 900, "en", "", "1", key=1))
    engine.streams_opened[1].sink.on_segment(Segment("from the watch", 0, 900, "en", "", "1", key=1))
    assert sorted((r["text"], r["device_id"]) for r in _rows(sid)) == [
        ("from the phone", "iphone-17pm"), ("from the watch", "watch-9")]


def test_live_engine_error_hands_back_edge_lane(engine):
    conn, client = _connect(caps=_pcm_caps())
    _audio(conn)
    engine.streams_opened[0].sink.on_error("unauthenticated: bad key")
    warning = [f for f in client.of("state") if f.get("warning") == "speech_engine"]
    assert warning and "Fake" in warning[0]["message"]
    relane = [f for f in client.of("ready") if f.get("relane")]
    assert relane and relane[-1]["lane"] == live_ws.LANE_EDGE and "engine" not in relane[-1]
    _audio(conn, ts_ms=3000)
    assert len(engine.streams_opened) == 1


def test_error_on_a_device_that_cannot_transcribe_keeps_the_server_lane(engine):
    conn, client = _connect(caps=_pcm_caps(stt="none"))
    _audio(conn)
    engine.streams_opened[0].sink.on_error("service_unavailable: try later")
    assert [f for f in client.of("state") if f.get("warning") == "speech_engine"]
    assert not [f for f in client.of("ready") if f.get("relane")]


def test_spooled_audio_batch_is_transcribed_not_streamed(engine, monkeypatch):
    spooled = []
    monkeypatch.setattr(live_speech, "transcribe_spool",
                        lambda sid, device, chunks, codec, rate: spooled.append((sid, device, chunks, codec, rate)))
    conn, _client = _connect(caps=_pcm_caps())
    payload = b"\x02\x00" * 160
    conn.on_text(json.dumps({"t": "audio", "codec": "pcm16", "rate": 16000,
                             "chunks": [{"data": base64.b64encode(payload).decode(), "ts_ms": 500}]}))
    assert spooled == [(conn.live_session_id, "iphone-17pm", [(payload, 500)], "pcm16", 16000)]
    assert engine.streams_opened == []


def test_rest_audio_batch_is_transcribed_too(engine, monkeypatch):
    spooled = []
    monkeypatch.setattr(live_speech, "transcribe_spool",
                        lambda sid, device, chunks, codec, rate: spooled.append((sid, device, len(chunks))))
    conn, _client = _connect(caps=_pcm_caps())
    payload = b"\x02\x00" * 160
    handler, claimed = _post("/api/live/audio", {
        "live_session_id": conn.live_session_id, "device_id": "iphone-17pm", "codec": "pcm16",
        "rate": 16000, "chunks": [{"data": base64.b64encode(payload).decode(), "ts_ms": 700}]})
    assert claimed and handler.status == 200
    assert spooled == [(conn.live_session_id, "iphone-17pm", 1)]


def test_transcribe_spool_appends_what_it_heard(monkeypatch):
    fake = FakeLiveEngine(final=Segment("said while offline", 500, 1400, "en", "", "2", key=1))
    monkeypatch.setattr(live_speech, "live_engine", lambda: fake)
    conn, _client = _connect(caps=_pcm_caps())
    thread = live_speech.transcribe_spool(conn.live_session_id, "iphone-17pm",
                                          [(b"\x01\x00" * 320, 500)], "pcm16", 16000)
    thread.join(5)
    assert [(r["text"], r["device_id"]) for r in _rows(conn.live_session_id)] == [
        ("said while offline", "iphone-17pm")]
    assert fake.streams_opened[0].fed == [(b"\x01\x00" * 320, 500)]


def test_edge_lane_is_untouched_without_an_engine(monkeypatch):
    monkeypatch.setattr(live_speech, "live_engine", lambda: None)
    conn, client = _connect(caps=_pcm_caps())
    assert client.first("ready")["lane"] == live_ws.LANE_EDGE
    _audio(conn)
    assert conn.engine_lane is None


# ── bug sweep ──────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def fresh_engine_memory():
    live_speech.reset_for_tests()
    yield
    live_speech.reset_for_tests()


def _frame(conn, seq, ts_ms, n=320):
    conn.on_binary(live_ws.encode_audio_frame(seq, ts_ms, b"\x01\x00" * n))


def test_frames_replayed_after_a_reconnect_are_not_heard_twice(engine):
    conn1, _ = _connect(caps=_pcm_caps())
    sid = conn1.live_session_id
    for seq in range(1, 6):
        _frame(conn1, seq, seq * 20)
    conn1.close()
    conn2, _ = _connect(caps=_pcm_caps(), resume={"live_session_id": sid, "after_seq": 0})
    for seq in range(3, 8):              # the phone re-sends its in-flight window
        _frame(conn2, seq, seq * 20)
    assert len(engine.streams_opened[1].fed) == 2


def test_an_app_restart_that_counts_from_one_again_is_still_heard(engine):
    conn1, _ = _connect(caps=_pcm_caps())
    sid = conn1.live_session_id
    for seq in range(1, 2001):
        _frame(conn1, seq, seq * 20, n=16)
    conn1.close()
    conn2, _ = _connect(caps=_pcm_caps(), resume={"live_session_id": sid, "after_seq": 0})
    _frame(conn2, 1, 50_000)
    assert len(engine.streams_opened[1].fed) == 1


def test_a_failing_engine_is_not_retried_on_every_reconnect(engine):
    conn1, client1 = _connect(caps=_pcm_caps())
    sid = conn1.live_session_id
    _audio(conn1)
    engine.streams_opened[0].sink.on_error("unauthenticated: bad key")
    conn1.close()
    _conn2, client2 = _connect(caps=_pcm_caps(), resume={"live_session_id": sid, "after_seq": 0})
    assert client2.first("ready")["lane"] == live_ws.LANE_EDGE


def test_the_engine_comes_back_for_a_device_that_cannot_transcribe(engine, monkeypatch):
    conn, client = _connect(caps=_pcm_caps(stt="none"))
    _audio(conn)
    engine.streams_opened[0].sink.on_error("service_unavailable: try later")
    monkeypatch.setattr(live_speech, "_now", lambda: 10 ** 9)   # the backoff has passed
    _audio(conn, ts_ms=9000, seq=2)
    assert len(engine.streams_opened) == 2
    assert client.of("ready")[-1].get("engine") == "Fake"


def test_a_slow_finish_at_end_is_not_reported_as_a_failure(engine, monkeypatch):
    conn, client = _connect(caps=_pcm_caps())
    _audio(conn)
    stream = engine.streams_opened[0]
    stream.finish = lambda timeout=5.0: stream.sink.on_error("timed out waiting for Soniox") or []
    conn.on_text(json.dumps({"t": "end"}))
    assert not [f for f in client.of("ready") if f.get("relane")]
    assert live_store.get_session(conn.live_session_id)["state"] != "recording"


def test_the_translation_target_is_a_language_soniox_knows(engine):
    from api import live_config
    live_config.save({"translate": True, "primary_language": "en-US"})
    conn, _ = _connect(caps=_pcm_caps())
    _audio(conn)
    assert engine.options[0]["translate_to"] == "en"


def test_device_lines_are_ignored_while_an_engine_hears_the_device(engine):
    conn, _ = _connect(caps=_pcm_caps())
    conn.on_text(json.dumps({"t": "seg", "local_label": "A", "text": "Apple heard this too",
                             "ts_start_ms": 0, "ts_end_ms": 900, "final": True}))
    assert _rows(conn.live_session_id) == []


def test_a_line_with_no_recorded_length_can_still_teach(monkeypatch):
    from api import live_voiceprint
    seen = []
    monkeypatch.setattr(live_voiceprint, "identify", lambda vec, **kw: seen.append(kw["learn"]))
    live_ws._decide_identity("s", 1, {"ts_start_ms": 500, "ts_end_ms": 500}, [0.0] * 256, source="device")
    assert seen == [True]


def test_a_codec_nobody_can_decode_hands_the_phone_back(engine):
    conn, client = _connect(caps=_edge_caps(codec="flac", rate=16000))
    _audio(conn)
    assert [f for f in client.of("state") if f.get("warning") == "speech_engine"]
    assert client.of("ready")[-1]["lane"] == live_ws.LANE_EDGE


def test_a_stream_that_cannot_open_hands_the_phone_back(engine, monkeypatch):
    def boom(*a, **kw):
        raise RuntimeError("no socket")
    monkeypatch.setattr(engine, "open_stream", boom)
    conn, client = _connect(caps=_pcm_caps())
    _audio(conn)
    assert client.of("ready")[-1]["lane"] == live_ws.LANE_EDGE


def test_a_line_is_retried_when_the_store_is_busy(engine, monkeypatch):
    real = live_ws.append_and_publish
    attempts = []

    def flaky(*a, **kw):
        attempts.append(1)
        if len(attempts) == 1:
            import sqlite3
            raise sqlite3.OperationalError("database is locked")
        return real(*a, **kw)
    monkeypatch.setattr(live_ws, "append_and_publish", flaky)
    conn, _ = _connect(caps=_pcm_caps())
    _audio(conn)
    engine.streams_opened[0].sink.on_segment(Segment("worth keeping", 0, 900, "en", "", "1", key=1))
    assert [r["text"] for r in _rows(conn.live_session_id)] == ["worth keeping"]
