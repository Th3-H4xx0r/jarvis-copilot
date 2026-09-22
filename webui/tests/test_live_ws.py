"""Live Jarvis protocol: the promises a recording device relies on.

What is worth testing here is not that the frames parse. It is:

* a device that cannot be trusted to label voices does not get the edge lane,
  including — especially — one whose embedding model is a different checkpoint;
* all four ingestion shapes land in the same transcript with one monotonic
  `seq`, because `seq` is every client's resume cursor;
* a viewer that attaches mid-session sees what it missed AND what arrives while
  it is attaching, which is the ordering the chat-mirror work got wrong first;
* a watcher that explodes does not take capture with it (design §8: capture is
  the floor).
"""
from __future__ import annotations

import io
import json
import struct
import sys
import threading
import time
import types
from urllib.parse import urlparse

import pytest

import api as api_pkg
from api import config as api_config
from api import live_config, live_store, live_ws
from api import models as api_models

# Captured before the autouse stub below replaces the module, so the contract
# test can still check the real hooks. Absent is a legitimate state: watchers are
# a separate layer and capture is specified to work without them.
try:
    from api import live_watchers as _real_live_watchers
except Exception:  # pragma: no cover - depends on another layer being installed
    _real_live_watchers = None


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(api_config, "STATE_DIR", tmp_path)
    sessions = tmp_path / "sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(api_models, "SESSION_DIR", sessions)
    monkeypatch.setattr(api_models, "SESSION_INDEX_FILE", sessions / "_index.json")
    # api.routes imported the same names from api.config, so the chat-delete path
    # needs them redirected too or it unlinks from the shared test state dir.
    import api.routes as _routes
    monkeypatch.setattr(_routes, "SESSION_DIR", sessions)
    monkeypatch.setattr(_routes, "SESSION_INDEX_FILE", sessions / "_index.json")
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(tmp_path / "config.yaml"))
    api_config.reload_config()
    # Whether the host has the agent's STT deps installed must not decide
    # whether these tests pass.
    monkeypatch.setattr(live_ws, "_server_stt_cache", False)
    live_store.reset_for_tests()
    yield tmp_path
    live_ws.close_writers()
    live_store.reset_for_tests()
    api_config.reload_config()


@pytest.fixture(autouse=True)
def no_watcher_threads_left_running():
    """On-demand watchers now run off-thread; one outliving its test raced into
    another file's suite and made it flake."""
    yield
    deadline = time.time() + 5
    while time.time() < deadline and live_ws._watcher_inflight:
        time.sleep(0.01)
    assert not live_ws._watcher_inflight, "a watcher job outlived its test"


@pytest.fixture(autouse=True)
def stubbed_watchers(monkeypatch):
    """Capture tests must not depend on a configured LLM provider.

    The real watchers arm timers and call models, so leaving them live would make
    every `seg` in this file spend network time and leave a timer running past the
    test. The tests that care about watcher wiring install their own.
    """
    _install_watchers(monkeypatch,
                      on_segment_appended=lambda sid, seq: None,
                      on_session_ended=lambda sid: None)


# ── harness ────────────────────────────────────────────────────────────────


def _edge_caps(**over):
    caps = {
        "audio": "stream", "text": "stream", "stt": "on_device",
        "embed": "on_device",
        # Read from DEFAULTS rather than hardcoded: the assertion is "matches the
        # server", not "is this particular string".
        "embed_model": live_config.DEFAULTS["embed_model"],
        "codec": "opus", "rate": 16000, "speak": True,
    }
    caps.update(over)
    return caps


class _Client:
    """Collects server->client frames in order."""

    def __init__(self):
        self.frames = []

    def __call__(self, frame):
        self.frames.append(frame)

    def of(self, kind):
        return [f for f in self.frames if f.get("t") == kind]

    def first(self, kind):
        found = self.of(kind)
        assert found, f"no {kind!r} frame in {self.frames!r}"
        return found[0]


def _connect(caps=None, **hello):
    client = _Client()
    conn = live_ws.LiveConnection(client)
    payload = {"t": "hello", "device_id": "iphone-17pm", "device_kind": "ios",
               "caps": _edge_caps() if caps is None else caps}
    payload.update(hello)
    conn.on_text(json.dumps(payload))
    return conn, client


class _FakeHandler:
    def __init__(self):
        self.wfile = io.BytesIO()
        self.headers = {}
        self.status = None
        self.sent_headers = {}

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        self.sent_headers[key] = value

    def end_headers(self):
        pass

    def payload(self):
        return json.loads(self.wfile.getvalue().decode("utf-8"))


def _post(path, body):
    handler = _FakeHandler()
    claimed = live_ws.handle_live_post(handler, urlparse(path), body)
    return handler, claimed


def _get(path):
    handler = _FakeHandler()
    claimed = live_ws.handle_live_get(handler, urlparse(path))
    return handler, claimed


def _put(path, body):
    handler = _FakeHandler()
    claimed = live_ws.handle_live_put(handler, urlparse(path), body)
    return handler, claimed


def _start_session(**body):
    handler, claimed = _post("/api/live/session/start", body)
    assert claimed and handler.status == 200
    return handler.payload()


# ── lane assignment (design §2.1, §5.3) ────────────────────────────────────


def test_a_device_with_on_device_stt_embedding_and_our_model_gets_the_edge_lane():
    assert live_ws.assign_lane(_edge_caps()) == live_ws.LANE_EDGE


def test_a_mismatched_embed_model_is_refused_the_edge_lane():
    """The interlock. Vectors from two checkpoints are not comparable, so this
    device must not be allowed to write speaker identity — it loses the lane
    instead of silently corrupting who said what."""
    caps = _edge_caps(embed_model="some-other-checkpoint-v9")
    assert live_ws.assign_lane(caps) == live_ws.LANE_SERVER


def test_changing_the_servers_embed_model_drops_a_previously_edge_device():
    assert live_ws.assign_lane(_edge_caps()) == live_ws.LANE_EDGE
    live_config.save({"embed_model": "wespeaker-resnet34-v2"})
    assert live_ws.assign_lane(_edge_caps()) == live_ws.LANE_SERVER


@pytest.mark.parametrize("caps", [
    None,
    {},
    _edge_caps(stt="server"),
    _edge_caps(embed="server"),
    _edge_caps(embed_model=""),
])
def test_anything_less_than_the_full_declaration_streams_audio_instead(caps):
    """A future device joins by declaring less; it gets the server lane and no
    server code changes."""
    assert live_ws.assign_lane(caps) == live_ws.LANE_SERVER


def test_the_ready_frame_states_the_lane_and_the_servers_own_capabilities():
    _conn, client = _connect()
    ready = client.first("ready")
    assert ready["lane"] == live_ws.LANE_EDGE
    assert ready["server_caps"]["embed_model"] == live_config.DEFAULTS["embed_model"]
    # Honesty about what the server cannot do yet matters more than the True:
    # a device that believes in server-side embedding would trust identification
    # that does not exist until the phase-5 spike lands.
    assert ready["server_caps"]["embed"] is False


# ── handshake, paired chat, resume ─────────────────────────────────────────


def test_hello_opens_a_live_session_and_pairs_a_normal_chat():
    conn, client = _connect(source_label="AirPods Pro", title="Standup")
    ready = client.first("ready")

    assert ready["live_session_id"] == conn.live_session_id
    assert ready["seq"] == 0
    stored = live_store.get_session(conn.live_session_id)
    assert stored["state"] == "recording"
    # The pairing is two-way: the chat id is in the handshake AND on the live row,
    # so a device that reconnects finds the same chat.
    assert ready["chat_session_id"]
    assert stored["chat_session_id"] == ready["chat_session_id"]

    chat = api_models.Session.load(ready["chat_session_id"])
    assert chat is not None
    assert chat.source_tag == live_ws.LIVE_SOURCE_TAG
    assert len(chat.messages) == 1
    assert conn.live_session_id in chat.messages[0]["content"]


def test_utterances_do_not_stream_into_the_paired_chat():
    """Streaming every utterance in would rewrite the prompt prefix every few
    seconds, which AGENTS.md forbids. The chat keeps its header; the transcript
    lives behind the tool."""
    conn, client = _connect()
    chat_id = client.first("ready")["chat_session_id"]
    for i in range(3):
        _final_seg(conn, f"utterance {i}", start=i * 1000, end=i * 1000 + 900)

    chat = api_models.Session.load(chat_id)
    assert len(chat.messages) == 1
    assert len(live_store.segments_after(conn.live_session_id, 0)) == 3


def test_resume_replays_only_what_the_device_has_not_seen():
    first, _client = _connect()
    sid = first.live_session_id
    for i in range(3):
        _final_seg(first, f"line {i}", start=i * 1000, end=i * 1000 + 500)

    resumed, client2 = _connect(resume={"live_session_id": sid, "after_seq": 1})

    assert resumed.live_session_id == sid
    assert client2.first("ready")["seq"] == 3
    assert [f["seq"] for f in client2.of("seg")] == [2, 3]
    assert [f["text"] for f in client2.of("seg")] == ["line 1", "line 2"]


def test_resuming_with_after_seq_zero_replays_the_whole_backlog():
    """Zero is a cursor, not a missing one: a client that lost its state says 0
    and must be caught up, not left silently empty."""
    first, _client = _connect()
    sid = first.live_session_id
    for i in range(3):
        _final_seg(first, f"line {i}", start=i * 1000, end=i * 1000 + 500)

    _resumed, client2 = _connect(resume={"live_session_id": sid, "after_seq": 0})
    assert [f["seq"] for f in client2.of("seg")] == [1, 2, 3]


def test_resuming_a_session_this_server_no_longer_has_starts_a_fresh_one():
    """A phone drops its stream about once a minute (§8) and spools. If the
    session is gone it must be told, not left spooling against a ghost."""
    conn, client = _connect(resume={"live_session_id": "deadbeef" * 4,
                                    "after_seq": 400})
    ready = client.first("ready")
    assert ready["live_session_id"] != "deadbeef" * 4
    assert ready["seq"] == 0
    assert live_store.get_session(conn.live_session_id) is not None


def test_a_frame_before_hello_is_refused_rather_than_silently_dropped():
    client = _Client()
    conn = live_ws.LiveConnection(client)
    conn.on_text(json.dumps({"t": "seg", "partial": False, "text": "hi"}))
    assert client.first("error")["code"] == "not_ready"


def test_an_unknown_frame_type_is_reported():
    conn, client = _connect()
    conn.on_text(json.dumps({"t": "telemetry"}))
    assert client.first("error")["code"] == "unknown_frame"


def test_malformed_json_does_not_kill_the_connection():
    conn, client = _connect()
    conn.on_text("{not json")
    assert client.first("error")["code"] == "bad_json"
    _final_seg(conn, "still recording")
    assert len(live_store.segments_after(conn.live_session_id, 0)) == 1


# ── ingestion shape 1: streaming text ──────────────────────────────────────


def _final_seg(conn, text, start=0, end=1000, **extra):
    frame = {"t": "seg", "partial": False, "text": text,
             "ts_start_ms": start, "ts_end_ms": end}
    frame.update(extra)
    conn.on_text(json.dumps(frame))


def test_partials_accumulate_and_the_final_frame_commits_one_segment():
    conn, _client = _connect()
    conn.on_text(json.dumps({"t": "seg", "partial": True, "text": "the pod",
                             "ts_start_ms": 1000, "lang": "en"}))
    conn.on_text(json.dumps({"t": "seg", "partial": True, "text": " firmware",
                             "ts_end_ms": 2000}))
    assert live_store.segments_after(conn.live_session_id, 0) == []

    conn.on_text(json.dumps({"t": "seg", "partial": False, "ts_end_ms": 2500}))

    rows = live_store.segments_after(conn.live_session_id, 0)
    assert [r["text"] for r in rows] == ["the pod firmware"]
    assert (rows[0]["ts_start_ms"], rows[0]["ts_end_ms"]) == (1000, 2500)
    assert rows[0]["lang"] == "en"
    assert rows[0]["label_state"] == live_store.LABEL_PROVISIONAL


def test_a_final_frame_with_its_own_text_replaces_the_accumulation():
    """Apple's SpeechAnalyzer re-states the whole utterance at the end.
    Concatenating would store it twice."""
    conn, _client = _connect()
    conn.on_text(json.dumps({"t": "seg", "partial": True, "text": "hel"}))
    _final_seg(conn, "hello there")
    assert [r["text"] for r in live_store.segments_after(conn.live_session_id, 0)] \
        == ["hello there"]


def test_two_tracks_on_one_device_do_not_interleave_into_one_sentence():
    conn, _client = _connect()
    conn.on_text(json.dumps({"t": "seg", "partial": True, "text": "mine",
                             "track": "me"}))
    conn.on_text(json.dumps({"t": "seg", "partial": True, "text": "theirs",
                             "track": "local:3"}))
    conn.on_text(json.dumps({"t": "seg", "partial": False, "track": "me"}))
    conn.on_text(json.dumps({"t": "seg", "partial": False, "track": "local:3"}))
    assert [r["text"] for r in live_store.segments_after(conn.live_session_id, 0)] \
        == ["mine", "theirs"]


def test_an_empty_final_frame_stores_nothing():
    conn, _client = _connect()
    conn.on_text(json.dumps({"t": "seg", "partial": False, "text": "   "}))
    assert live_store.segments_after(conn.live_session_id, 0) == []


# ── ingestion shape 2: batch text ──────────────────────────────────────────


def test_batch_text_over_the_socket_lands_in_the_same_transcript():
    conn, _client = _connect()
    conn.on_text(json.dumps({"t": "text", "segments": [
        {"ts_start_ms": 0, "ts_end_ms": 900, "text": "first", "lang": "en",
         "local_label": "me"},
        {"ts_start_ms": 900, "ts_end_ms": 1800, "text": "second"},
    ]}))
    rows = live_store.segments_after(conn.live_session_id, 0)
    assert [(r["seq"], r["text"]) for r in rows] == [(1, "first"), (2, "second")]
    assert rows[0]["local_label"] == "me"


def test_batch_text_over_rest_lands_in_the_same_transcript():
    session = _start_session(device_id="glasses", source_label="Jarvis glasses")
    sid = session["live_session_id"]
    handler, _ = _post("/api/live/text", {
        "live_session_id": sid,
        "segments": [{"ts_start_ms": 0, "ts_end_ms": 500, "text": "over rest"}],
    })
    assert handler.status == 200
    assert handler.payload()["segments"][0]["seq"] == 1
    assert handler.payload()["last_seq"] == 1


def test_rest_text_for_an_unknown_session_is_a_404_not_a_new_session():
    handler, _ = _post("/api/live/text", {
        "live_session_id": "nope", "segments": [
            {"ts_start_ms": 0, "ts_end_ms": 1, "text": "x"}]})
    assert handler.status == 404
    assert live_store.list_sessions() == []


# ── ingestion shape 3: streaming audio ─────────────────────────────────────


def test_a_binary_audio_frame_carries_seq_and_timestamp_in_its_header():
    frame = live_ws.encode_audio_frame(4417, 1_700_000_000_123, b"packet")
    assert len(frame) == live_ws.AUDIO_HEADER_BYTES + len(b"packet")
    assert live_ws.decode_audio_frame(frame) == (4417, 1_700_000_000_123, b"packet")
    # Big-endian, fixed width — the wire format other devices will implement.
    assert struct.unpack(">I", frame[:4])[0] == 4417


def test_a_truncated_audio_frame_is_reported_not_guessed_at():
    conn, client = _connect()
    conn.on_binary(b"\x00\x01\x02")
    assert client.first("error")["code"] == "short_frame"


def test_streamed_audio_is_written_to_disk_and_registered_honestly():
    conn, _client = _connect()
    sid = conn.live_session_id
    conn.on_binary(live_ws.encode_audio_frame(1, 1000, b"opus-packet-one"))
    conn.on_binary(live_ws.encode_audio_frame(2, 1020, b"opus-packet-two"))

    chunks = live_ws.close_writers(sid)
    assert len(chunks) == 1
    rows = live_store.audio_chunks(sid)
    assert len(rows) == 1
    path = live_store.audio_dir(sid) / rows[0]["path"].rsplit("/", 1)[-1]
    assert path.exists()
    assert rows[0]["bytes"] == path.stat().st_size > 0
    # The client sent bare Opus packets and we have no container, so the file is
    # NOT a .opus file and does not claim to be one.
    assert not path.name.endswith(".opus")
    assert "opus-packets" in rows[0]["codec"]
    # Packet boundaries are preserved by a length prefix, otherwise the file
    # would be undecodable.
    blob = path.read_bytes()
    assert struct.unpack(">I", blob[:4])[0] == len(b"opus-packet-one")


def test_pcm_audio_is_stored_raw_with_its_rate_recorded():
    conn, _client = _connect(caps=_edge_caps(codec="pcm16", rate=24000))
    sid = conn.live_session_id
    conn.on_binary(live_ws.encode_audio_frame(1, 1000, b"\x01\x02" * 8))
    live_ws.close_writers(sid)
    row = live_store.audio_chunks(sid)[0]
    assert row["codec"] == "pcm16@24000"
    assert row["bytes"] == 16, "raw PCM must not gain framing bytes"


def test_audio_rolls_into_a_new_chunk_so_a_crash_costs_one_chunk(monkeypatch):
    # Zero means "this chunk is already old enough", so the second packet rolls.
    monkeypatch.setattr(live_ws, "_AUDIO_CHUNK_SECONDS", 0)
    conn, _client = _connect()
    sid = conn.live_session_id
    conn.on_binary(live_ws.encode_audio_frame(1, 10_000, b"early"))
    conn.on_binary(live_ws.encode_audio_frame(2, 12_000, b"later"))
    live_ws.close_writers(sid)
    rows = live_store.audio_chunks(sid)
    assert len(rows) == 2
    assert rows[0]["ts0_ms"] == 10_000 and rows[1]["ts0_ms"] == 12_000
    assert len({r["path"] for r in rows}) == 2, "each chunk needs its own file"


def test_a_client_cannot_force_a_chunk_per_packet_with_its_own_clock():
    """Rolling on the CLIENT's timestamp let a client alternating a small and a
    huge ts_ms create a file and a live_audio row every 20 ms."""
    conn, _client = _connect()
    sid = conn.live_session_id
    for i in range(8):
        ts = 1000 if i % 2 == 0 else 9_000_000
        conn.on_binary(live_ws.encode_audio_frame(i, ts, b"x" * 64))
    live_ws.close_writers(sid)
    assert len(live_store.audio_chunks(sid)) == 1, "the wall clock decides rolls"


def test_a_disk_that_will_not_accept_writes_drops_oldest_and_says_so(monkeypatch):
    """§8: server-side overload or a full disk degrades loudly. Growing server
    memory without limit, or losing audio silently, are both worse."""
    monkeypatch.setattr(live_ws, "_WS_AUDIO_BUFFER_LIMIT_BYTES", 512)
    monkeypatch.setattr(live_ws._AudioWriter, "_flush_locked", lambda self: None)
    conn, client = _connect()
    for i in range(6):
        conn.on_binary(live_ws.encode_audio_frame(i, 1000 + i, b"x" * 200))

    warnings = [f for f in client.of("state")
                if f.get("warning") == "audio_buffer_overflow"]
    assert warnings, "a dropping buffer must tell the client"
    assert warnings[0]["dropped_bytes"] > 0
    # Capture is the floor: text still records while audio is degraded.
    _final_seg(conn, "still transcribing")
    assert len(live_store.segments_after(conn.live_session_id, 0)) == 1


# ── ingestion shape 4: batch audio ─────────────────────────────────────────


def test_batch_audio_over_rest_is_written_and_registered():
    import base64
    session = _start_session(device_id="glasses")
    sid = session["live_session_id"]
    handler, _ = _post("/api/live/audio", {
        "live_session_id": sid, "device_id": "glasses", "codec": "pcm16",
        "chunks": [
            {"seq": 1, "ts_ms": 1000,
             "data": base64.b64encode(b"\x00\x01" * 4).decode()},
            {"seq": 2, "ts_ms": 1020,
             "data": base64.b64encode(b"\x02\x03" * 4).decode()},
        ],
    })
    assert handler.status == 200
    assert handler.payload() == {"ok": True, "chunks": 2, "written": 2,
                                 "bytes": 16}
    live_ws.close_writers(sid)
    assert live_store.audio_chunks(sid)[0]["bytes"] == 16


def test_batch_audio_over_the_socket_uses_the_same_path():
    import base64
    conn, _client = _connect(caps=_edge_caps(codec="pcm16"))
    conn.on_text(json.dumps({"t": "audio", "chunks": [
        {"ts_ms": 1000, "data": base64.b64encode(b"abcd").decode()}]}))
    live_ws.close_writers(conn.live_session_id)
    assert live_store.audio_chunks(conn.live_session_id)[0]["bytes"] == 4


def test_audio_that_is_not_base64_is_rejected_with_a_message():
    session = _start_session()
    handler, _ = _post("/api/live/audio", {
        "live_session_id": session["live_session_id"],
        "chunks": [{"data": "!!!! not base64 !!!!", "ts_ms": 1}]})
    assert handler.status == 400


# ── seq and cursors ────────────────────────────────────────────────────────


def test_seq_is_one_monotonic_sequence_across_every_ingestion_shape():
    """Two devices and two transports feed one session; a repeated or skipped
    seq would silently duplicate or drop an utterance on the other device."""
    conn, client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "streamed")
    conn.on_text(json.dumps({"t": "text", "segments": [
        {"ts_start_ms": 1000, "ts_end_ms": 2000, "text": "ws batch"}]}))
    _post("/api/live/text", {"live_session_id": sid, "segments": [
        {"ts_start_ms": 2000, "ts_end_ms": 3000, "text": "rest batch"}]})

    rows = live_store.segments_after(sid, 0)
    assert [r["seq"] for r in rows] == [1, 2, 3]
    assert live_store.get_session(sid)["last_seq"] == 3


def test_the_transcript_endpoint_answers_a_cursor_not_a_whole_history():
    conn, _client = _connect()
    sid = conn.live_session_id
    for i in range(4):
        _final_seg(conn, f"line {i}", start=i * 1000, end=i * 1000 + 500)

    handler, _ = _get(f"/api/live/transcript?live_session_id={sid}&after_seq=2")
    payload = handler.payload()
    assert [s["seq"] for s in payload["segments"]] == [3, 4]
    assert payload["last_seq"] == 4


def test_the_transcript_endpoint_404s_for_a_session_it_does_not_have():
    handler, _ = _get("/api/live/transcript?live_session_id=ghost")
    assert handler.status == 404


def test_sessions_lists_what_is_recording():
    first = _start_session(title="one")
    _start_session(title="two")
    handler, _ = _get("/api/live/sessions")
    rows = handler.payload()["sessions"]
    assert len(rows) == 2
    assert {r["state"] for r in rows} == {"recording"}

    _post("/api/live/session/end", {"live_session_id": first["live_session_id"]})
    ended = [r for r in _get("/api/live/sessions")[0].payload()["sessions"]
             if r["id"] == first["live_session_id"]][0]
    assert ended["state"] == "ended"
    assert ended["ended_at"]


# ── fan-out to viewers (design §2.4) ───────────────────────────────────────


class _SseSink:
    """A wfile that hangs up once it has seen `limit` SSE events.

    That is how these tests end: the handler's loop is infinite by design and a
    real client's disconnect is what stops it.
    """

    def __init__(self, limit):
        self.limit = limit
        self.chunks = []
        self.events = 0

    def write(self, data):
        self.chunks.append(data)
        if data.startswith(b"event:"):
            self.events += 1
            if self.events >= self.limit:
                raise BrokenPipeError("viewer went away")

    def flush(self):
        pass

    def body(self):
        return b"".join(self.chunks).decode("utf-8")


class _SseHandler(_FakeHandler):
    def __init__(self, sink):
        super().__init__()
        self.wfile = sink


def _run_sse(sid, sink, after_seq=0):
    handler = _SseHandler(sink)
    path = f"/api/live/events?live_session_id={sid}&after_seq={after_seq}"
    thread = threading.Thread(
        target=live_ws.handle_live_get, args=(handler, urlparse(path)),
        daemon=True)
    thread.start()
    return thread


def _parse_sse(body):
    """(event, payload) pairs from an SSE body, keepalives dropped."""
    out = []
    for block in body.split("\n\n"):
        name = data = None
        for line in block.splitlines():
            if line.startswith("event: "):
                name = line[7:]
            elif line.startswith("data: "):
                data = line[6:]
        if name and data:
            out.append((name, json.loads(data)))
    return out


def _join(thread, timeout=5.0):
    """A stream thread that outlived its test would keep touching the store after
    the tmp state is torn down."""
    thread.join(timeout=timeout)
    assert not thread.is_alive(), "SSE handler did not stop on disconnect"


def _await_subscribers(sid, count, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if live_ws.LIVE_EVENTS.subscriber_count(sid) >= count:
            return True
        time.sleep(0.01)
    return False


def test_two_viewers_on_one_live_session_both_receive_the_segment():
    sid = _start_session(device_id="phone")["live_session_id"]
    sinks = [_SseSink(2), _SseSink(2)]
    threads = [_run_sse(sid, sink) for sink in sinks]
    assert _await_subscribers(sid, 2), "both viewers should be subscribed"

    live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=500,
                               text="heard by both")

    for thread in threads:
        _join(thread)
    for sink in sinks:
        body = sink.body()
        assert "event: snapshot" in body
        assert "event: seg" in body
        assert "heard by both" in body
    assert live_ws.LIVE_EVENTS.subscriber_count(sid) == 0, "must unsubscribe"


def test_a_viewer_gets_the_backlog_it_asked_for_in_its_snapshot():
    conn, _client = _connect()
    sid = conn.live_session_id
    for i in range(3):
        _final_seg(conn, f"line {i}", start=i * 1000, end=i * 1000 + 500)

    sink = _SseSink(1)
    _join(_run_sse(sid, sink, after_seq=1))
    body = sink.body()
    assert "line 1" in body and "line 2" in body
    assert "line 0" not in body, "after_seq is a cursor, not a suggestion"


def test_a_segment_that_lands_while_the_snapshot_is_being_taken_is_not_lost(
        monkeypatch):
    """The ordering the chat mirror got wrong: subscribe first, then snapshot.
    Published with no subscriber attached, this frame goes nowhere — the bus
    deliberately has no offline buffer."""
    sid = _start_session()["live_session_id"]
    real_segments_after = live_store.segments_after
    fired = []

    def racing(session_id, after_seq=0, limit=500):
        if not fired:
            fired.append(True)
            live_ws.publish(sid, "seg", {"live_session_id": sid, "seq": 1,
                                         "text": "arrived mid-snapshot"})
        return real_segments_after(session_id, after_seq, limit)

    monkeypatch.setattr(live_store, "segments_after", racing)
    sink = _SseSink(2)
    _join(_run_sse(sid, sink))
    assert fired, "the snapshot must have been taken"
    assert "arrived mid-snapshot" in sink.body()


def test_a_snapshot_segment_and_a_live_seg_have_the_same_shape():
    """`snapshot` is not in the design but the web client depends on it and it is
    what fills a reconnect gap. The risk it introduces is one seq reaching a
    client as two different shapes; a client keys on seq, so that is a bug even
    when both shapes are individually valid."""
    conn, _client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "in the backlog")

    sink = _SseSink(2)
    thread = _run_sse(sid, sink)
    assert _await_subscribers(sid, 1)
    live_ws.append_and_publish(sid, ts_start_ms=2000, ts_end_ms=3000,
                               text="arrived live")
    _join(thread)

    events = _parse_sse(sink.body())
    snapshot = next(d for name, d in events if name == "snapshot")
    live_seg = next(d for name, d in events if name == "seg")
    backlog_seg = snapshot["segments"][0]
    assert backlog_seg["seq"] == 1 and live_seg["seq"] == 2
    assert set(backlog_seg) == set(live_seg), (
        "a segment must look the same whether it arrived in the snapshot or live")
    for field in live_ws.SEGMENT_FRAME_FIELDS:
        assert field in backlog_seg and field in live_seg, field


def test_the_shape_holds_even_if_a_stored_row_loses_a_field(monkeypatch):
    """The guarantee is structural, not a coincidence of both paths reading the
    same table: a row missing a field still reaches the client in one shape."""
    sid = _start_session()["live_session_id"]
    live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=500, text="hi")
    real = live_store.segments_after

    def lossy(session_id, after_seq=0, limit=500):
        rows = real(session_id, after_seq, limit)
        for row in rows:
            row.pop("translation", None)
            row.pop("audio_ref", None)
        return rows

    monkeypatch.setattr(live_store, "segments_after", lossy)
    payload = _get(f"/api/live/transcript?live_session_id={sid}")[0].payload()
    assert set(payload["segments"][0]) >= set(live_ws.SEGMENT_FRAME_FIELDS)


def test_a_replayed_segment_over_the_socket_has_that_same_shape():
    first, _client = _connect()
    sid = first.live_session_id
    _final_seg(first, "said earlier")

    resumed, client2 = _connect(resume={"live_session_id": sid, "after_seq": 0})
    replayed = client2.first("seg")
    live = live_ws.segment_frame(
        live_ws.append_and_publish(sid, ts_start_ms=9000, ts_end_ms=9500,
                                   text="said now"))
    assert set(replayed) - {"t"} == set(live)


def test_the_events_endpoint_needs_a_session_id():
    handler, claimed = _get("/api/live/events")
    assert claimed and handler.status == 400


def test_a_socket_forwards_another_devices_segment_to_this_device():
    conn, client = _connect()
    conn.on_bus_event("seg", {"seq": 9, "text": "from the glasses"})
    assert client.first("seg")["text"] == "from the glasses"


def test_a_spoken_reply_only_goes_to_a_device_that_declared_speak():
    speaker, speaker_client = _connect(caps=_edge_caps(speak=True))
    silent, silent_client = _connect(caps=_edge_caps(speak=False))
    frame = {"text": "your 3pm moved"}
    speaker.on_bus_event("speak", dict(frame))
    silent.on_bus_event("speak", dict(frame))
    assert speaker_client.of("speak")
    assert silent_client.of("speak") == []


def test_a_dropped_fan_out_event_tells_the_client_to_resync():
    conn, client = _connect()
    conn.on_bus_event("resync", {})
    assert client.first("state")["warning"] == "resync"


# ── watchers must never stop capture (design §8) ───────────────────────────


def _install_watchers(monkeypatch, **funcs):
    module = types.ModuleType("api.live_watchers")
    for name, func in funcs.items():
        setattr(module, name, func)
    monkeypatch.setitem(sys.modules, "api.live_watchers", module)
    monkeypatch.setattr(api_pkg, "live_watchers", module, raising=False)
    return module


def _no_watchers(monkeypatch):
    """Make the watcher import fail the way a missing file would.

    `api/live_watchers.py` belongs to another layer and may not be installed;
    `None` in `sys.modules` reproduces that deterministically, and the package
    attribute has to go too or `from api import live_watchers` finds the cached
    module instead of attempting an import.
    """
    monkeypatch.delattr(api_pkg, "live_watchers", raising=False)
    monkeypatch.setitem(sys.modules, "api.live_watchers", None)


def test_capture_works_with_no_watcher_module_installed(monkeypatch):
    _no_watchers(monkeypatch)
    conn, client = _connect()
    _final_seg(conn, "nobody is watching")
    assert len(live_store.segments_after(conn.live_session_id, 0)) == 1
    assert client.of("error") == []
    conn.on_text(json.dumps({"t": "end"}))
    assert live_store.get_session(conn.live_session_id)["state"] == "ended"


def test_the_real_watcher_module_exposes_the_hooks_capture_calls():
    """The two layers meet at these four names. If the watcher layer renames one,
    capture silently stops triggering it — a failure no other test would see."""
    if _real_live_watchers is None:
        pytest.skip("api/live_watchers.py is not installed in this checkout")
    for name in ("on_segment_appended", "on_session_ended", "run_fact_check",
                 "run_translate"):
        assert callable(getattr(_real_live_watchers, name, None)), name


def test_a_watcher_that_raises_does_not_break_capture(monkeypatch):
    seen = []

    def exploding(live_session_id, seq):
        seen.append((live_session_id, seq))
        raise RuntimeError("watcher exploded")

    def exploding_end(live_session_id):
        raise RuntimeError("end watcher exploded")

    _install_watchers(monkeypatch, on_segment_appended=exploding,
                      on_session_ended=exploding_end)

    conn, client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "recorded anyway")
    _final_seg(conn, "and this one too", start=1000, end=2000)

    assert [s[1] for s in seen] == [1, 2], "the watcher was called"
    rows = live_store.segments_after(sid, 0)
    assert [r["text"] for r in rows] == ["recorded anyway", "and this one too"]
    assert client.of("error") == []

    conn.on_text(json.dumps({"t": "end"}))
    assert live_store.get_session(sid)["state"] == "ended"


def _await(flag, timeout=5.0):
    assert flag.wait(timeout), "the watcher job never ran"


def test_fact_check_is_accepted_and_runs_off_the_request_thread(monkeypatch):
    """It builds a whole AIAgent and runs a turn with web tools. Doing that in
    the handler thread meant an uncancellable request the edge would 504 while
    the agent kept going, so the verdict comes back over the insight fan-out."""
    ran = threading.Event()
    seen = []

    def fake(sid, seq):
        seen.append((sid, seq))
        ran.set()
        return {"ok": True, "verdict": "unsupported"}

    _install_watchers(monkeypatch, run_fact_check=fake)
    conn, _client = _connect()
    _final_seg(conn, "the pod shipped in 1997")

    handler, _ = _post("/api/live/factcheck",
                       {"live_session_id": conn.live_session_id, "seq": 1})
    assert handler.status == 202
    body = handler.payload()
    assert body["accepted"] is True and body["job_id"]
    assert body["delivery"] == "insight"
    _await(ran)
    assert seen == [(conn.live_session_id, 1)]


def test_translate_passes_the_target_language_through(monkeypatch):
    ran = threading.Event()
    calls = []

    def fake(sid, seq, target):
        calls.append(target)
        ran.set()
        return {"ok": True, "translation": "hola"}

    _install_watchers(monkeypatch, run_translate=fake)
    live_config.save({"translate": True})
    conn, _client = _connect()
    _final_seg(conn, "hello")
    handler, _ = _post("/api/live/translate",
                       {"live_session_id": conn.live_session_id, "seq": 1,
                        "target": "es"})
    assert handler.status == 202
    _await(ran)
    assert calls == ["es"]


def test_a_feature_that_is_off_is_refused_synchronously_with_the_setting():
    """The client renders what it gets, and it cannot hear about a refusal that
    happens inside a background job — so "it is off" is answered here."""
    live_config.save({"translate": False})
    conn, _client = _connect()
    _final_seg(conn, "hola")
    handler, _ = _post("/api/live/translate",
                       {"live_session_id": conn.live_session_id, "seq": 1})
    body = handler.payload()
    assert handler.status == 200
    assert body["ok"] is False
    assert body["setting"] == "live.translate"
    assert "off" in body["error"]


def test_a_watcher_that_fails_in_the_background_says_so_over_the_fan_out(
        monkeypatch):
    """Otherwise the tap is a spinner that never resolves: the insight channel
    has no failure frame, so the failure arrives as a state warning."""
    ran = threading.Event()

    def declining(sid, seq):
        ran.set()
        return {"ok": False, "error": "no sources found"}

    _install_watchers(monkeypatch, run_fact_check=declining)
    conn, _client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "check this")
    viewer = live_ws.subscribe(sid)
    try:
        handler, _ = _post("/api/live/factcheck",
                           {"live_session_id": sid, "seq": 1})
        assert handler.status == 202
        _await(ran)
        event, data = viewer.get(timeout=5)
    finally:
        live_ws.unsubscribe(sid, viewer)
    assert event == "state"
    assert data["warning"] == "run_fact_check_failed"
    assert data["message"] == "no sources found"


def test_a_watcher_that_raises_in_the_background_also_reports(monkeypatch):
    ran = threading.Event()

    def exploding(sid, seq):
        ran.set()
        raise RuntimeError("provider said no")

    _install_watchers(monkeypatch, run_fact_check=exploding)
    conn, _client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "check this")
    viewer = live_ws.subscribe(sid)
    try:
        assert _post("/api/live/factcheck",
                     {"live_session_id": sid, "seq": 1})[0].status == 202
        _await(ran)
        event, data = viewer.get(timeout=5)
    finally:
        live_ws.unsubscribe(sid, viewer)
    assert event == "state" and data["warning"] == "run_fact_check_failed"
    # The reason the provider gave is logged, not handed to the client: it can
    # carry a base URL or a key in a query string.
    assert "provider said no" not in json.dumps(data)


def test_too_many_concurrent_checks_are_refused_rather_than_queued(monkeypatch):
    release = threading.Event()
    started = threading.Semaphore(0)

    def slow(sid, seq):
        started.release()
        release.wait(5)
        return {"ok": True}

    _install_watchers(monkeypatch, run_fact_check=slow)
    conn, _client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "one")
    try:
        for _ in range(live_ws._MAX_WATCHER_INFLIGHT):
            assert _post("/api/live/factcheck",
                         {"live_session_id": sid, "seq": 1})[0].status == 202
        for _ in range(live_ws._MAX_WATCHER_INFLIGHT):
            assert started.acquire(timeout=5)
        handler, _ = _post("/api/live/factcheck",
                           {"live_session_id": sid, "seq": 1})
        assert handler.status == 429
        assert handler.payload()["ok"] is False
    finally:
        release.set()


def test_an_on_demand_watcher_call_reports_a_missing_watcher_rather_than_lying(
        monkeypatch):
    """Unlike the capture path, this is a button the user pressed — silence would
    look like a hung request."""
    _no_watchers(monkeypatch)
    conn, _client = _connect()
    _final_seg(conn, "check this")
    handler, _ = _post("/api/live/factcheck",
                       {"live_session_id": conn.live_session_id, "seq": 1})
    assert handler.status == 503


# ── speakers ───────────────────────────────────────────────────────────────


def test_renaming_a_voice_keeps_its_id_and_its_history():
    speaker = live_store.create_speaker(name="Speaker 2")
    conn, _client = _connect()
    _final_seg(conn, "something they said")
    live_store.assign_speaker(conn.live_session_id, 1, speaker["id"])

    handler, _ = _post("/api/live/speaker/rename",
                       {"speaker_id": speaker["id"], "name": "Rahul"})
    assert handler.status == 200
    assert handler.payload()["speaker"]["name"] == "Rahul"
    rows = live_store.segments_after(conn.live_session_id, 0)
    assert rows[0]["speaker_id"] == speaker["id"], "id must not change"


def test_merging_two_clusters_relabels_the_loser_in_place():
    keep = live_store.create_speaker(name="Rahul")
    drop = live_store.create_speaker()
    conn, _client = _connect()
    _final_seg(conn, "first half")
    live_store.assign_speaker(conn.live_session_id, 1, drop["id"])

    handler, _ = _post("/api/live/speaker/merge",
                       {"from_id": drop["id"], "into_id": keep["id"]})
    assert handler.status == 200
    assert handler.payload()["segments_moved"] == 1
    assert live_store.get_speaker(drop["id"]) is None
    assert live_store.segments_after(conn.live_session_id, 0)[0]["speaker_id"] \
        == keep["id"]


def test_the_speakers_endpoint_carries_samples_for_the_naming_ui():
    speaker = live_store.create_speaker()
    conn, _client = _connect()
    _final_seg(conn, "a thing this voice said")
    live_store.assign_speaker(conn.live_session_id, 1, speaker["id"])

    handler, _ = _get("/api/live/speakers")
    rows = handler.payload()["speakers"]
    assert [s["text"] for s in rows[0]["samples"]] == ["a thing this voice said"]


def test_a_rename_reaches_a_viewer_of_an_ENDED_session():
    """Naming a voice is exactly what someone does while reviewing a finished
    conversation. Scoping the fan-out to recording sessions meant a second
    device viewing that transcript never learned."""
    conn, _client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "something they said")
    speaker = live_store.create_speaker()
    live_store.assign_speaker(sid, 1, speaker["id"])
    _post("/api/live/session/end", {"live_session_id": sid})
    assert live_store.get_session(sid)["state"] == "ended"

    viewer = live_ws.subscribe(sid)
    try:
        _post("/api/live/speaker/rename",
              {"speaker_id": speaker["id"], "name": "Rahul"})
        event, data = viewer.get(timeout=2)
    finally:
        live_ws.unsubscribe(sid, viewer)
    assert event == "speaker"
    assert (data["op"], data["name"]) == ("rename", "Rahul")


def test_a_merge_reaches_a_viewer_of_an_ended_session():
    conn, _client = _connect()
    sid = conn.live_session_id
    _final_seg(conn, "first half")
    keep, drop = live_store.create_speaker(), live_store.create_speaker()
    live_store.assign_speaker(sid, 1, drop["id"])
    _post("/api/live/session/end", {"live_session_id": sid})

    viewer = live_ws.subscribe(sid)
    try:
        _post("/api/live/speaker/merge",
              {"from_id": drop["id"], "into_id": keep["id"]})
        event, data = viewer.get(timeout=2)
    finally:
        live_ws.unsubscribe(sid, viewer)
    assert event == "speaker"
    assert (data["op"], data["from_id"], data["into_id"]) == \
        ("merge", drop["id"], keep["id"])


def test_a_rename_reaches_a_viewer_of_an_old_session_beyond_a_listing_page():
    """The fan-out targets the sessions someone is watching, not the most recent
    N a session listing would return."""
    watched = _start_session(title="the old one")["live_session_id"]
    for _ in range(3):
        _start_session()
    speaker = live_store.create_speaker()

    viewer = live_ws.subscribe(watched)
    try:
        monkey = live_store.list_sessions
        # Prove the target set is not "whatever a listing returns" by making the
        # listing return nothing at all.
        live_store.list_sessions = lambda limit=50: []
        try:
            _post("/api/live/speaker/rename",
                  {"speaker_id": speaker["id"], "name": "Ada"})
            event, data = viewer.get(timeout=2)
        finally:
            live_store.list_sessions = monkey
    finally:
        live_ws.unsubscribe(watched, viewer)
    assert event == "speaker" and data["name"] == "Ada"


def test_a_rename_without_an_id_is_refused():
    handler, _ = _post("/api/live/speaker/rename", {"name": "Rahul"})
    assert handler.status == 400


# ── storage and deletion (design §3.1) ─────────────────────────────────────


def _session_with_audio(text="said something", ts_ms=1000, speaker_id=""):
    conn, client = _connect(caps=_edge_caps(codec="pcm16"))
    sid = conn.live_session_id
    _final_seg(conn, text, start=0, end=2000)
    if speaker_id:
        live_store.assign_speaker(sid, 1, speaker_id)
    conn.on_binary(live_ws.encode_audio_frame(1, ts_ms, b"\x01\x02" * 64))
    live_ws.close_writers(sid)
    return sid, client


def test_storage_reports_what_is_on_disk_and_whose_it_roughly_is():
    speaker = live_store.create_speaker(name="Rahul")
    sid, _client = _session_with_audio(speaker_id=speaker["id"])

    handler, _ = _get("/api/live/storage")
    summary = handler.payload()
    assert summary["total_bytes"] == 128
    assert [row["live_session_id"] for row in summary["per_session"]] == [sid]
    approx = summary["per_speaker_approx"][0]
    assert approx["id"] == speaker["id"]
    assert approx["approx_bytes"] == 128
    assert "estimated" in summary["note"]


def test_deleting_a_session_takes_its_audio_and_its_transcript():
    sid, _client = _session_with_audio()
    path = live_store.audio_chunks(sid)[0]["path"]

    handler, _ = _post("/api/live/delete", {"kind": "session", "id": sid})
    assert handler.status == 200
    assert handler.payload()["freed_bytes"] == 128
    assert live_store.get_session(sid) is None
    assert live_store.segments_after(sid, 0) == []
    from pathlib import Path
    assert not Path(path).exists()


def test_forgetting_a_voice_drops_its_words_and_keeps_the_recording():
    """The surgical option: this person's transcript and voiceprint go; the
    recording stays, because it contains other people too."""
    speaker = live_store.create_speaker(name="Rahul")
    sid, _client = _session_with_audio(speaker_id=speaker["id"])
    live_store.add_embedding(speaker["id"], [0.1, 0.2], "ecapa-v1")
    path = live_store.audio_chunks(sid)[0]["path"]

    handler, _ = _post("/api/live/delete",
                       {"kind": "speaker_forget", "id": speaker["id"]})
    assert handler.status == 200
    assert handler.payload()["segments_removed"] == 1
    assert handler.payload()["audio_kept"] is True
    assert live_store.get_speaker(speaker["id"]) is None
    assert live_store.segments_after(sid, 0) == []
    assert live_store.embeddings_for_model("ecapa-v1") == []
    from pathlib import Path
    assert Path(path).exists(), "audio must survive forgetting a voice"


def test_deleting_a_voices_recordings_takes_whole_chunks_and_leaves_the_words():
    """Deliberately blunt, and the dialog says so: a chunk holds whoever else
    was talking."""
    speaker = live_store.create_speaker(name="Rahul")
    sid, _client = _session_with_audio(speaker_id=speaker["id"])
    path = live_store.audio_chunks(sid)[0]["path"]

    handler, _ = _post("/api/live/delete",
                       {"kind": "speaker_audio", "id": speaker["id"]})
    assert handler.status == 200
    assert handler.payload()["chunks_deleted"] == 1
    from pathlib import Path
    assert not Path(path).exists()
    assert live_store.audio_chunks(sid) == []
    assert [r["text"] for r in live_store.segments_after(sid, 0)] \
        == ["said something"], "the words are still true"


def test_deleting_a_day_removes_every_session_started_that_day():
    """§3.1 offers per-day delete next to per-session, and the storage panel's
    per-day rows are decorative without it."""
    import time as _time
    from pathlib import Path

    sid, _client = _session_with_audio()
    path = live_store.audio_chunks(sid)[0]["path"]
    today = _time.strftime("%Y-%m-%d", _time.localtime(
        live_store.get_session(sid)["started_at"]))

    handler, _ = _post("/api/live/delete", {"kind": "day", "id": today})
    assert handler.status == 200
    body = handler.payload()
    assert body["day"] == today
    assert body["sessions_deleted"] == 1
    assert body["freed_bytes"] == 128
    assert live_store.get_session(sid) is None
    assert not Path(path).exists()


def test_deleting_a_day_leaves_other_days_alone():
    sid, _client = _session_with_audio()
    handler, _ = _post("/api/live/delete", {"kind": "day", "id": "1999-01-01"})
    assert handler.status == 200
    assert handler.payload()["sessions_deleted"] == 0
    assert live_store.get_session(sid) is not None


def test_a_malformed_day_is_refused_instead_of_reporting_success():
    """"0 sessions deleted" for a typo'd day reads as "that day is gone"."""
    for bad_day in ("yesterday", "2026-13", "2026/09/21", ""):
        handler, _ = _post("/api/live/delete", {"kind": "day", "id": bad_day})
        assert handler.status == 400, bad_day


def test_an_unknown_delete_kind_is_refused_rather_than_guessed():
    handler, _ = _post("/api/live/delete", {"kind": "everything", "id": "x"})
    assert handler.status == 400


def test_delete_requires_a_target():
    handler, _ = _post("/api/live/delete", {"kind": "session"})
    assert handler.status == 400


# ── orphaned audio a crash left behind ─────────────────────────────────────


def test_the_startup_sweep_adopts_a_chunk_a_crash_left_unregistered(monkeypatch):
    """A chunk is registered when it rolls, so a crash leaves a real file with
    no row: invisible to the storage panel and missed by delete_session's
    unlink, which is what made a per-day delete leave audio behind."""
    monkeypatch.setattr(live_ws, "_sweep_done", False)
    sid = _start_session()["live_session_id"]
    orphan = live_store.audio_dir(sid) / "999.pcm"
    orphan.write_bytes(b"\x01\x02" * 32)
    assert live_store.audio_chunks(sid) == []

    result = live_ws.sweep_orphan_audio_once()

    assert result == {"adopted": 1, "bytes": 64}
    assert [r["bytes"] for r in live_store.audio_chunks(sid)] == [64]
    # The real bug: it is now reachable by a delete.
    storage = _get("/api/live/storage")[0].payload()
    assert storage["total_bytes"] == 64
    handler, _ = _post("/api/live/delete", {"kind": "session", "id": sid})
    assert handler.payload()["freed_bytes"] == 64
    assert not orphan.exists()


def test_the_startup_sweep_runs_at_most_once_per_process(monkeypatch):
    monkeypatch.setattr(live_ws, "_sweep_done", False)
    calls = []
    monkeypatch.setattr(live_store, "sweep_orphan_audio",
                        lambda: calls.append(1) or {"adopted": 0, "bytes": 0})
    assert live_ws.sweep_orphan_audio_once() == {"adopted": 0, "bytes": 0}
    assert live_ws.sweep_orphan_audio_once() is None
    assert len(calls) == 1


def test_a_failing_sweep_does_not_propagate_to_startup(monkeypatch):
    monkeypatch.setattr(live_ws, "_sweep_done", False)

    def boom():
        raise OSError("disk went away")

    monkeypatch.setattr(live_store, "sweep_orphan_audio", boom)
    assert live_ws.sweep_orphan_audio_once() is None


# ── live.enabled gates NEW capture only ────────────────────────────────────


def test_turning_live_off_refuses_a_new_session_and_names_the_setting():
    live_config.save({"enabled": False})
    handler, claimed = _post("/api/live/session/start", {"device_id": "phone"})
    assert claimed and handler.status == 403
    body = handler.payload()
    assert body["setting"] == "live.enabled"
    assert "live.enabled" in body["error"]
    assert live_store.list_sessions() == []


def test_turning_live_off_refuses_a_new_websocket_handshake():
    live_config.save({"enabled": False})
    client = _Client()
    conn = live_ws.LiveConnection(client)
    conn.on_text(json.dumps({"t": "hello", "device_id": "iphone-17pm",
                             "caps": _edge_caps()}))
    err = client.first("error")
    assert err["code"] == "live_disabled"
    assert err["setting"] == "live.enabled"
    assert client.of("ready") == []
    assert conn.ready is False
    assert live_store.list_sessions() == []


def test_a_session_already_recording_may_still_resume_when_live_is_turned_off():
    """A real phone drops its stream about once a minute (§8). Killing an
    in-flight conversation mid-utterance is not what the toggle is for."""
    first, _client = _connect()
    sid = first.live_session_id
    _final_seg(first, "before the switch")

    live_config.save({"enabled": False})
    resumed, client2 = _connect(resume={"live_session_id": sid, "after_seq": 0})

    assert client2.of("error") == []
    assert resumed.ready is True
    assert client2.first("ready")["live_session_id"] == sid
    _final_seg(resumed, "after the switch", start=2000, end=3000)
    assert [r["text"] for r in live_store.segments_after(sid, 0)] == \
        ["before the switch", "after the switch"]


def test_resuming_an_ended_session_is_new_capture_and_is_refused_when_off():
    conn, _client = _connect()
    sid = conn.live_session_id
    _post("/api/live/session/end", {"live_session_id": sid})
    live_config.save({"enabled": False})

    client = _Client()
    again = live_ws.LiveConnection(client)
    again.on_text(json.dumps({"t": "hello", "caps": _edge_caps(),
                              "resume": {"live_session_id": sid,
                                         "after_seq": 0}}))
    assert client.first("error")["code"] == "live_disabled"
    assert again.ready is False


def test_reading_and_deleting_still_work_with_live_turned_off():
    """The point of the toggle is to stop recording, not to lock the user out of
    what was already recorded."""
    sid, _client = _session_with_audio()
    speaker = live_store.create_speaker(name="Rahul")
    live_config.save({"enabled": False})

    assert _get("/api/live/sessions")[0].status == 200
    assert _get(f"/api/live/transcript?live_session_id={sid}")[0].status == 200
    assert _get("/api/live/speakers")[0].status == 200
    assert _get("/api/live/storage")[0].status == 200
    assert _get("/api/live/config")[0].status == 200
    assert _post("/api/live/speaker/rename",
                 {"speaker_id": speaker["id"], "name": "Rahul K"})[0].status == 200
    assert _post("/api/live/delete", {"kind": "session", "id": sid})[0].status == 200
    assert live_store.get_session(sid) is None


def test_turning_live_back_on_lets_capture_start_again():
    live_config.save({"enabled": False})
    assert _post("/api/live/session/start", {})[0].status == 403
    live_config.save({"enabled": True})
    assert _post("/api/live/session/start", {})[0].status == 200


# ── config over HTTP ───────────────────────────────────────────────────────


def test_the_config_endpoint_returns_effective_values_and_the_defaults():
    handler, _ = _get("/api/live/config")
    payload = handler.payload()
    assert payload["config"] == live_config.DEFAULTS
    assert payload["defaults"] == live_config.DEFAULTS


def test_a_put_updates_one_key_and_a_get_reads_it_back():
    handler, claimed = _put("/api/live/config", {"monitor": False})
    assert claimed and handler.status == 200
    assert handler.payload()["config"]["monitor"] is False
    assert _get("/api/live/config")[0].payload()["config"]["monitor"] is False


def test_the_same_write_works_over_post_for_clients_that_cannot_put():
    handler, _ = _post("/api/live/config", {"config": {"translate": True}})
    assert handler.status == 200
    assert handler.payload()["config"]["translate"] is True


def test_an_invalid_setting_is_a_400_and_changes_nothing():
    handler, _ = _put("/api/live/config", {"reply_mode": "semaphore"})
    assert handler.status == 400
    assert _get("/api/live/config")[0].payload()["config"]["reply_mode"] == \
        live_config.DEFAULTS["reply_mode"]


def test_an_unknown_setting_key_is_reported_as_ignored():
    handler, _ = _put("/api/live/config", {"montior": True})
    assert handler.status == 200
    assert handler.payload()["ignored_keys"] == ["montior"]


# ── dispatch contract ──────────────────────────────────────────────────────


def test_an_unknown_live_path_is_not_claimed_so_routes_can_404():
    assert live_ws.handle_live_get(_FakeHandler(),
                                   urlparse("/api/live/nonsense")) is False
    assert live_ws.handle_live_post(_FakeHandler(),
                                    urlparse("/api/live/nonsense"), {}) is False
    assert live_ws.handle_live_put(_FakeHandler(),
                                   urlparse("/api/live/nonsense"), {}) is False


def test_the_websocket_handler_only_claims_its_own_path():
    assert live_ws.handle_websocket(_FakeHandler(),
                                    urlparse("/api/voice/s2s/ws")) is False


def test_a_real_socket_completes_the_handshake_and_carries_both_shapes():
    """The transport itself, over a socketpair with a real wsproto client.

    Everything above drives `LiveConnection` directly, which is the point of that
    split — but it leaves the parts that only exist on the wire untested: the
    handshake reconstructed from the already-consumed HTTP headers, frame
    encoding both ways, the fan-out thread writing to the same socket, and the
    chunk being flushed when the client hangs up.
    """
    import re
    import socket as _socket

    from wsproto import ConnectionType, WSConnection
    from wsproto.events import (AcceptConnection, BytesMessage, CloseConnection,
                                Request, TextMessage)

    server_sock, client_sock = _socket.socketpair()
    client = WSConnection(ConnectionType.CLIENT)
    request_bytes = client.send(Request(host="localhost", target=live_ws.LIVE_WS_PATH))
    # The server rebuilds the request from the headers the HTTP handler already
    # read off the wire, so the key has to match what this client generated or
    # the accept hash is rejected.
    key = re.search(rb"Sec-WebSocket-Key: (\S+)", request_bytes).group(1).decode()

    class _WsHandler(_FakeHandler):
        command = "GET"
        path = live_ws.LIVE_WS_PATH

        def __init__(self):
            super().__init__()
            self.connection = server_sock
            self.headers = {
                "Host": "localhost", "Upgrade": "websocket",
                "Connection": "Upgrade", "Sec-WebSocket-Key": key,
                "Sec-WebSocket-Version": "13",
            }

    pump = threading.Thread(
        target=live_ws.handle_websocket,
        args=(_WsHandler(), urlparse(live_ws.LIVE_WS_PATH)), daemon=True)
    pump.start()

    frames = []

    def _await_accept(timeout=5.0):
        client_sock.settimeout(0.2)
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                data = client_sock.recv(65536)
            except _socket.timeout:
                continue
            if not data:
                return False
            client.receive_data(data)
            for event in client.events():
                if isinstance(event, AcceptConnection):
                    return True
        return False

    def _read_one(timeout=5.0):
        client_sock.settimeout(0.2)
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                data = client_sock.recv(65536)
            except _socket.timeout:
                continue
            except OSError:
                return None
            if not data:
                return None
            client.receive_data(data)
            for event in client.events():
                if isinstance(event, TextMessage):
                    frames.append(json.loads(event.data))
                    return frames[-1]
                if isinstance(event, (AcceptConnection, CloseConnection)):
                    continue
        return None

    try:
        assert _await_accept(), "server did not accept the upgrade"
        client_sock.sendall(client.send(TextMessage(data=json.dumps({
            "t": "hello", "device_id": "iphone-17pm", "device_kind": "ios",
            "caps": _edge_caps(codec="pcm16")}))))
        ready = _read_one()
        assert ready and ready["t"] == "ready" and ready["lane"] == live_ws.LANE_EDGE
        sid = ready["live_session_id"]

        client_sock.sendall(client.send(TextMessage(data=json.dumps({
            "t": "seg", "partial": False, "text": "over a real socket",
            "ts_start_ms": 0, "ts_end_ms": 900}))))
        # Arrives back over the fan-out bus, which is how a second device would
        # have received it too.
        seg = _read_one()
        assert seg and seg["t"] == "seg" and seg["text"] == "over a real socket"

        client_sock.sendall(client.send(BytesMessage(
            data=live_ws.encode_audio_frame(1, 1000, b"\x01\x02" * 8))))
        client_sock.sendall(client.send(CloseConnection(code=1000)))
        pump.join(timeout=5)
        assert not pump.is_alive(), "the pump must exit when the client closes"

        assert [r["text"] for r in live_store.segments_after(sid, 0)] == \
            ["over a real socket"]
        # A dropped socket is the normal path (§8), so the chunk is flushed and
        # registered rather than left as an orphan file.
        assert live_store.audio_chunks(sid)[0]["bytes"] == 16
    finally:
        for sock in (client_sock, server_sock):
            try:
                sock.close()
            except OSError:
                pass


def test_ending_a_session_flushes_its_audio_and_marks_it_ended():
    conn, client = _connect(caps=_edge_caps(codec="pcm16"))
    sid = conn.live_session_id
    conn.on_binary(live_ws.encode_audio_frame(1, 1000, b"\x01\x02" * 8))

    handler, _ = _post("/api/live/session/end", {"live_session_id": sid})
    assert handler.status == 200
    assert live_store.get_session(sid)["state"] == "ended"
    # The chunk is registered rather than left as an orphan file on disk.
    assert live_store.audio_chunks(sid)[0]["bytes"] == 16


# ── capture is the floor: a store error must not cost the socket ────────────


def test_a_locked_database_costs_the_utterance_not_the_socket(monkeypatch):
    """`database is locked` is the EXPECTED outcome when the recorder, the
    watchers and the storage panel contend, and a full disk raises here too.
    Letting it escape reached the pump's blanket handler, whose `finally` closed
    the socket — losing the transport holding the client's spooled backlog,
    which `after_seq` cannot recover because the client has already moved on."""
    import sqlite3

    conn, client = _connect()
    sid = conn.live_session_id

    real_append = live_store.append_segment

    def locked(*a, **kw):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(live_store, "append_segment", locked)
    _final_seg(conn, "this one is lost")

    assert conn.closed is False, "the socket must survive a store error"
    assert client.first("error")["code"] == "store_unavailable"
    assert [f for f in client.of("state")
            if f.get("warning") == "store_unavailable"]

    # And capture resumes the moment the store does (restoring only this patch —
    # monkeypatch.undo() would also revert the fixture's state isolation).
    monkeypatch.setattr(live_store, "append_segment", real_append)
    _final_seg(conn, "this one lands", start=5000, end=6000)
    assert [r["text"] for r in live_store.segments_after(sid, 0)] == \
        ["this one lands"]


def test_a_locked_database_on_a_batch_also_keeps_the_socket(monkeypatch):
    import sqlite3

    conn, client = _connect()

    def locked(*a, **kw):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(live_store, "append_segment", locked)
    conn.on_text(json.dumps({"t": "text", "segments": [
        {"ts_start_ms": 0, "ts_end_ms": 500, "text": "batched"}]}))
    assert conn.closed is False
    assert client.first("error")["code"] == "store_unavailable"


def test_a_rest_batch_that_fails_partway_reports_what_landed(monkeypatch):
    """Answering a bare error after a partial write made the §8 spool re-upload
    duplicate those utterances under fresh seqs, which seq-dedup cannot catch."""
    sid = _start_session()["live_session_id"]
    real = live_store.append_segment
    calls = {"n": 0}

    def fail_on_second(*a, **kw):
        calls["n"] += 1
        if calls["n"] == 2:
            raise RuntimeError("store went away")
        return real(*a, **kw)

    monkeypatch.setattr(live_store, "append_segment", fail_on_second)
    handler, _ = _post("/api/live/text", {"live_session_id": sid, "segments": [
        {"ts_start_ms": 0, "ts_end_ms": 500, "text": "first"},
        {"ts_start_ms": 500, "ts_end_ms": 900, "text": "second"},
        {"ts_start_ms": 900, "ts_end_ms": 1200, "text": "third"},
    ]})
    body = handler.payload()
    assert handler.status == 503
    assert body["ok"] is False
    assert body["written"] == 1
    assert body["last_seq"] == 1
    assert len(live_store.segments_after(sid, 0)) == 1


def test_a_rest_audio_batch_with_one_bad_chunk_writes_nothing():
    import base64

    sid = _start_session()["live_session_id"]
    handler, _ = _post("/api/live/audio", {
        "live_session_id": sid, "codec": "pcm16", "chunks": [
            {"ts_ms": 1000, "data": base64.b64encode(b"good").decode()},
            {"ts_ms": 1020, "data": "!!! not base64 !!!"},
        ]})
    assert handler.status == 400
    live_ws.close_writers(sid)
    assert live_store.audio_chunks(sid) == [], "nothing may be written"


# ── audio framing survives an overflow ─────────────────────────────────────


def _decode_framed(path):
    """Walk the 4-byte length prefixes. Raises if the file ends mid-frame."""
    blob = path.read_bytes()
    packets, i = [], 0
    while i < len(blob):
        if i + 4 > len(blob):
            raise ValueError("truncated length prefix")
        (size,) = struct.unpack(">I", blob[i:i + 4])
        i += 4
        if i + size > len(blob):
            raise ValueError("truncated payload")
        packets.append(blob[i:i + size])
        i += size
    return packets


def test_an_overflow_never_leaves_a_half_frame_in_the_file(monkeypatch):
    """Cutting bytes off the front sliced mid-frame: the next flush appended half
    a length prefix and every packet after it was undecodable, while the file
    still claimed `…-len32` framing. Measured before the fix: 0 of 8 packets
    recoverable, including the newest audio the policy exists to preserve."""
    monkeypatch.setattr(live_ws, "_AUDIO_FLUSH_BYTES", 128)
    monkeypatch.setattr(live_ws, "_WS_AUDIO_BUFFER_LIMIT_BYTES", 512)
    conn, client = _connect()          # opus caps → framed profile
    sid = conn.live_session_id
    for i in range(24):
        conn.on_binary(live_ws.encode_audio_frame(i, 1000 + i, bytes([i]) * 100))
    live_ws.close_writers(sid)

    rows = live_store.audio_chunks(sid)
    assert rows, "some audio must have reached disk"
    from pathlib import Path
    total = 0
    for row in rows:
        assert "len32" in row["codec"]
        packets = _decode_framed(Path(row["path"]))  # raises on a half frame
        assert all(len(p) == 100 for p in packets)
        total += len(packets)
    assert total, "a chunk with intact framing must survive"


# ── one time base (design: ms since live_session.started_at) ────────────────


def test_an_epoch_timestamp_from_a_client_is_normalised_to_a_session_offset():
    session = _start_session(device_id="phone")
    sid = session["live_session_id"]
    started_ms = live_ws.session_started_ms(sid)
    handler, _ = _post("/api/live/text", {"live_session_id": sid, "segments": [
        {"ts_start_ms": started_ms + 5_000, "ts_end_ms": started_ms + 7_000,
         "text": "stamped in epoch ms"}]})
    assert handler.status == 200
    row = live_store.segments_after(sid, 0)[0]
    assert 4_000 <= row["ts_start_ms"] <= 6_000, row["ts_start_ms"]
    assert row["ts_end_ms"] > row["ts_start_ms"]


def test_a_segment_with_no_timestamp_gets_a_real_one():
    """At 0 it overlapped no chunk, so "delete every recording this voice is in"
    deleted nothing and still answered 200."""
    session = _start_session()
    sid = session["live_session_id"]
    _post("/api/live/text", {"live_session_id": sid,
                             "segments": [{"text": "no timestamps at all"}]})
    row = live_store.segments_after(sid, 0)[0]
    assert row["ts_start_ms"] > 0
    assert row["ts_end_ms"] >= row["ts_start_ms"]


def test_epoch_audio_and_untimed_text_still_place_a_voice_for_deletion():
    """The headline: a transcript in offsets against audio in epoch ms matched
    nothing, so a privacy delete reported success and deleted no audio."""
    import base64
    from pathlib import Path

    session = _start_session(device_id="phone")
    sid = session["live_session_id"]
    speaker = live_store.create_speaker(name="Rahul")
    # Text with no timestamps at all...
    _post("/api/live/text", {"live_session_id": sid,
                             "segments": [{"text": "something they said"}]})
    live_store.assign_speaker(sid, 1, speaker["id"])
    # ...and audio stamped in absolute epoch milliseconds.
    _post("/api/live/audio", {
        "live_session_id": sid, "codec": "pcm16",
        "chunks": [{"ts_ms": int(time.time() * 1000),
                    "data": base64.b64encode(b"\x01\x02" * 32).decode()}]})
    live_ws.close_writers(sid)
    path = live_store.audio_chunks(sid)[0]["path"]

    handler, _ = _post("/api/live/delete",
                       {"kind": "speaker_audio", "id": speaker["id"]})
    assert handler.status == 200
    assert handler.payload()["chunks_deleted"] == 1, \
        "the two clocks must land on one base or this silently deletes nothing"
    assert not Path(path).exists()


# ── path traversal: an id from a request body is not a path ─────────────────


@pytest.mark.parametrize("evil", [
    "../../victim_empty_dir",
    "/tmp/victim_empty_dir",
    "..",
    "a" * 31,
    "NOTHEX" + "0" * 26,
    "0123456789abcdef0123456789abcde/",
])
def test_a_session_id_that_is_a_path_is_refused(evil):
    """`Path(audio_root) / "/abs"` discards the root and ".." climbs out of it, so
    an unvalidated id turned this delete into an rmdir elsewhere on disk."""
    handler, claimed = _post("/api/live/delete", {"kind": "session", "id": evil})
    assert claimed and handler.status == 400, evil
    assert "hex" in handler.payload()["error"]


def test_a_traversing_delete_touches_nothing_outside_the_audio_root(tmp_path):
    """Bounded to empty directories by rmdir semantics — which still covers a
    lock dir, an empty mount point, or an empty skills directory."""
    from pathlib import Path

    victim = tmp_path.parent / "live-ws-traversal-victim"
    victim.mkdir(exist_ok=True)
    audio_root = Path(api_config.STATE_DIR) / "live"
    audio_root.mkdir(parents=True, exist_ok=True)
    relative = ".." * 0  # built below from the real distance to the victim
    import os
    relative = os.path.relpath(victim, audio_root)
    assert relative.startswith(".."), "the victim must be outside the root"
    try:
        handler, _ = _post("/api/live/delete",
                           {"kind": "session", "id": relative})
        assert handler.status == 400
        assert victim.exists(), "a directory outside the audio root was removed"
    finally:
        try:
            victim.rmdir()
        except OSError:
            pass


@pytest.mark.parametrize("kind", ["speaker_forget", "speaker_audio"])
def test_speaker_ids_are_validated_too(kind):
    handler, _ = _post("/api/live/delete", {"kind": kind, "id": "../../etc"})
    assert handler.status == 400


# ── deleting a recording deletes the chat that holds its substance ──────────


def test_deleting_a_session_also_deletes_its_paired_chat():
    """The watchers put the monitor notes and the end-of-session summary,
    decisions and action items in that chat. Leaving it behind meant "delete this
    recording" left the substance of the conversation in the chat list, in chat
    search, and mirrored to the phone."""
    conn, client = _connect()
    sid = conn.live_session_id
    chat_id = client.first("ready")["chat_session_id"]
    assert api_models.Session.load(chat_id) is not None

    handler, _ = _post("/api/live/delete", {"kind": "session", "id": sid})
    body = handler.payload()
    assert body["chat_deleted"] is True
    assert body["chat_session_id"] == chat_id
    assert api_models.Session.load(chat_id) is None
    assert not (api_models.SESSION_DIR / f"{chat_id}.json").exists()


def test_deleting_a_day_deletes_the_paired_chats_too():
    conn, client = _connect()
    chat_id = client.first("ready")["chat_session_id"]
    today = time.strftime("%Y-%m-%d", time.localtime(
        live_store.get_session(conn.live_session_id)["started_at"]))

    handler, _ = _post("/api/live/delete", {"kind": "day", "id": today})
    assert handler.payload()["chats_deleted"] == 1
    assert api_models.Session.load(chat_id) is None


def test_a_chat_that_cannot_be_deleted_is_reported_not_claimed(monkeypatch):
    conn, client = _connect()
    sid = conn.live_session_id
    chat_id = client.first("ready")["chat_session_id"]

    import api.routes as routes

    def refuse(_sid):
        raise OSError("read-only file system")

    monkeypatch.setattr(routes, "delete_chat_session", refuse)
    handler, _ = _post("/api/live/delete", {"kind": "session", "id": sid})
    body = handler.payload()
    assert body["ok"] is False
    assert body["chat_deleted"] is False
    assert chat_id in body["warning"]
    assert "remain" in body["warning"]
    # The recording itself is still gone; only the chat survived.
    assert live_store.get_session(sid) is None


# ── one socket, one session ─────────────────────────────────────────────────


def test_a_second_hello_is_refused_instead_of_orphaning_the_first_session():
    """It used to run straight through: the first session stayed 'recording'
    forever with no tail digest, its writer kept buffered audio that was never
    registered, its fan-out thread leaked, and a second paired chat appeared."""
    conn, client = _connect(caps=_edge_caps(codec="pcm16"))
    first_sid = conn.live_session_id
    first_chat = client.first("ready")["chat_session_id"]
    conn.on_binary(live_ws.encode_audio_frame(1, 1000, b"\x01\x02" * 8))

    conn.on_text(json.dumps({"t": "hello", "device_id": "iphone-17pm",
                             "caps": _edge_caps()}))

    err = client.first("error")
    assert err["code"] == "already_ready"
    assert err["live_session_id"] == first_sid
    assert len(client.of("ready")) == 1, "no second handshake"
    assert conn.live_session_id == first_sid
    assert len(live_store.list_sessions()) == 1, "no orphaned second session"
    # The first session's audio is still the connection's, and still flushable.
    live_ws.close_writers(first_sid)
    assert live_store.audio_chunks(first_sid)[0]["bytes"] == 16
    assert api_models.Session.load(first_chat) is not None


def test_a_re_hello_naming_this_session_switches_lane_instead_of_being_refused():
    """The iOS client re-sends hello MID-SESSION when on-device transcription
    gives up and it must fall back to the server lane. Refusing that left the
    phone believing it was still on the edge lane while no longer transcribing,
    so the transcript stopped with nothing saying why."""
    conn, client = _connect(caps=_edge_caps())
    sid = conn.live_session_id
    assert client.first("ready")["lane"] == "edge"

    conn.on_text(json.dumps({
        "t": "hello", "device_id": "iphone-17pm",
        "caps": _edge_caps(stt="none", embed="none", embed_model=""),
        "resume": {"live_session_id": sid, "after_seq": 0},
    }))

    assert client.of("error") == [], "a lane change is not an error"
    readys = client.of("ready")
    assert len(readys) == 2
    assert readys[-1]["lane"] == "server"
    assert readys[-1]["relane"] is True
    assert readys[-1]["live_session_id"] == sid, "same session, no new one"
    assert conn.live_session_id == sid
    assert len(live_store.list_sessions()) == 1, "no orphaned second session"


# ── a deleted session stays deleted ─────────────────────────────────────────


def test_audio_after_a_delete_is_refused_instead_of_resurrecting_the_session():
    """The socket has not noticed the delete: the next frame rebuilt a writer,
    audio_dir() re-created the directory and register_audio inserted rows for a
    session row that no longer exists — a ghost in the storage panel, missing
    from per_day's inner join, nothing to click in /api/live/sessions, and the
    orphan sweep refuses to adopt it because the session id has no row."""
    conn, client = _connect(caps=_edge_caps(codec="pcm16"))
    sid = conn.live_session_id
    conn.on_binary(live_ws.encode_audio_frame(1, 1000, b"\x01\x02" * 8))

    assert _post("/api/live/delete", {"kind": "session", "id": sid})[0].status == 200
    assert live_store.get_session(sid) is None

    from pathlib import Path

    conn.on_binary(live_ws.encode_audio_frame(2, 2000, b"\x03\x04" * 8))
    live_ws.close_writers(sid)

    assert client.first("error")["code"] == "session_deleted"
    assert live_store.audio_chunks(sid) == [], "no rows for a deleted session"
    assert (Path(api_config.STATE_DIR) / "live" / sid).exists() is False
    assert live_store.storage_summary()["total_bytes"] == 0


def test_a_rest_upload_after_a_delete_is_refused_with_a_reason():
    import base64

    session = _start_session(device_id="phone")
    sid = session["live_session_id"]
    _post("/api/live/delete", {"kind": "session", "id": sid})
    handler, _ = _post("/api/live/audio", {
        "live_session_id": sid, "codec": "pcm16",
        "chunks": [{"ts_ms": 1000, "data": base64.b64encode(b"abcd").decode()}]})
    # The session is gone, so the guard that rejects an unknown session answers
    # first — either way nothing is stored and the client is told.
    assert handler.status in (404, 409)
    assert live_store.audio_chunks(sid) == []


# ── a constant client clock must not collapse chunks onto one file ──────────


def test_every_chunk_gets_its_own_file_even_with_a_constant_timestamp(
        monkeypatch):
    """A constant ts_ms made every chunk reuse one filename: `open(…, "ab")`
    appended, and each roll registered another row for that path with the
    cumulative size, so deleting any one row unlinked the file the others
    pointed at."""
    from pathlib import Path

    monkeypatch.setattr(live_ws, "_AUDIO_CHUNK_SECONDS", 0)
    conn, _client = _connect(caps=_edge_caps(codec="pcm16"))
    sid = conn.live_session_id
    for _ in range(3):
        conn.on_binary(live_ws.encode_audio_frame(1, 5000, b"\x01" * 1000))
    live_ws.close_writers(sid)

    rows = live_store.audio_chunks(sid)
    assert len(rows) >= 2
    paths = [r["path"] for r in rows]
    assert len(set(paths)) == len(paths), "one file per chunk row"
    for row in rows:
        assert int(row["bytes"]) == Path(row["path"]).stat().st_size


# ── cross-origin websockets ────────────────────────────────────────────────


class _UpgradeHandler(_FakeHandler):
    command = "GET"
    path = live_ws.LIVE_WS_PATH

    def __init__(self, headers):
        super().__init__()
        self.headers = headers
        self.connection = None


def test_a_cross_origin_websocket_upgrade_is_refused():
    """CSRF does not apply to a GET, so without this the only thing stopping a
    page on another origin from opening this socket and reading every frame — a
    live transcript of the room — is the SameSite cookie."""
    handler = _UpgradeHandler({"Host": "localhost:8788",
                               "Origin": "https://evil.example",
                               "Upgrade": "websocket"})
    assert live_ws.handle_websocket(handler, urlparse(live_ws.LIVE_WS_PATH)) is True
    assert handler.status == 403
    assert b"cross-origin" in handler.wfile.getvalue()


def test_a_same_origin_upgrade_is_not_refused_by_the_origin_check():
    handler = _UpgradeHandler({"Host": "localhost:8788",
                               "Origin": "http://localhost:8788"})
    assert live_ws._origin_allowed(handler) is True


def test_a_non_browser_client_with_no_origin_is_allowed():
    """Same rule the write endpoints use: curl and the agent send no Origin."""
    assert live_ws._origin_allowed(_UpgradeHandler({"Host": "localhost:8788"})) \
        is True


# ── a bad frame is that frame's problem, not the connection's ──────────────


def test_an_unserialisable_frame_is_dropped_and_the_connection_survives():
    """One non-serialisable insight payload used to set closed=True: the socket
    stayed open accepting uploads while the device never received another frame,
    and nothing recorded why."""
    sent = []

    def picky(frame):
        sent.append(json.dumps(frame))  # raises TypeError like the real sender

    conn = live_ws.LiveConnection(picky)
    conn.on_text(json.dumps({"t": "hello", "caps": _edge_caps()}))
    assert conn.ready is True

    conn.on_bus_event("insight", {"text": "fine", "blob": {1, 2, 3}})
    assert conn.closed is False, "a bad frame must not one-way the socket"

    conn.on_bus_event("insight", {"text": "still delivered"})
    assert any("still delivered" in payload for payload in sent)


def test_a_dead_socket_does_close_the_connection():
    def dead(frame):
        raise BrokenPipeError("gone")

    conn = live_ws.LiveConnection(dead)
    conn.on_text(json.dumps({"t": "hello", "caps": _edge_caps()}))
    assert conn.closed is True


def test_a_source_frame_records_which_mic_is_capturing():
    """The client sends this at start and whenever the audio route changes. The
    server used to reject it as an unknown frame, which put "unsupported frame
    type 'source'" over the phone's controls while capture worked fine."""
    conn, client = _connect()
    sid = conn.live_session_id

    conn.on_text(json.dumps({"t": "source", "source_label": "AirPods Pro"}))

    assert client.of("error") == [], "a mic change is not an error"
    assert live_store.get_session(sid)["source_label"] == "AirPods Pro"

    conn.on_text(json.dumps({"t": "source", "source_label": "iPhone mic"}))
    assert live_store.get_session(sid)["source_label"] == "iPhone mic", \
        "a route change mid-session must update, not be ignored"


def test_a_source_frame_without_a_label_keeps_the_last_known_mic():
    conn, client = _connect()
    conn.on_text(json.dumps({"t": "source", "source_label": "AirPods Pro"}))
    conn.on_text(json.dumps({"t": "source"}))

    assert client.of("error") == []
    assert live_store.get_session(conn.live_session_id)["source_label"] == "AirPods Pro"
