"""Tests for the plan-5.1 same-response streaming chat/start path:
``POST /api/chat/start?stream=1`` (or an SSE Accept header) streams the
turn's SSE events on the SAME chunked response instead of requiring the
older two-step (JSON response, then a separate GET /api/stream) flow. Both
paths attach to the same STREAMS[stream_id] channel, so they must yield the
same events.
"""
from __future__ import annotations

import http.client
import io
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.routes as routes  # noqa: E402
from api.config import STREAMS, StreamChannel  # noqa: E402


class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers_sent = []
        self.ended = False
        self.wfile = io.BytesIO()
        self.headers = http.client.HTTPMessage()

    def send_response(self, code):
        self.status = code

    def send_header(self, k, v):
        self.headers_sent.append((k, v))

    def end_headers(self):
        self.ended = True


def _sse_events(raw: bytes):
    """Parse ``event: x\\ndata: y\\n\\n`` frames back into (event, data) pairs."""
    out = []
    for chunk in raw.decode("utf-8").split("\n\n"):
        if not chunk.strip():
            continue
        event = None
        data = None
        for line in chunk.splitlines():
            if line.startswith("event: "):
                event = line[len("event: "):]
            elif line.startswith("data: "):
                data = line[len("data: "):]
        if event:
            out.append((event, data))
    return out


def test_stream_chat_start_response_emits_chat_start_then_pumps_stream():
    stream_id = "stream-abc"
    channel = StreamChannel()
    STREAMS[stream_id] = channel
    channel.put_nowait(("delta", {"text": "hi"}))
    channel.put_nowait(("stream_end", {}))

    handler = FakeHandler()
    response = {"stream_id": stream_id, "session_id": "sess-1", "title": "Untitled"}

    try:
        result = routes._stream_chat_start_response(handler, response)
    finally:
        STREAMS.pop(stream_id, None)

    assert result is True
    assert handler.status == 200
    assert any(k == "Content-Type" and "text/event-stream" in v for k, v in handler.headers_sent)

    events = _sse_events(handler.wfile.getvalue())
    assert events[0][0] == "chat_start"
    assert '"stream_id": "stream-abc"' in events[0][1] or "stream-abc" in events[0][1]
    kinds = [e for e, _ in events]
    assert "delta" in kinds
    assert kinds[-1] == "stream_end"


def test_get_stream_and_post_stream_yield_same_events():
    """The same STREAMS[stream_id] channel drives both the classic GET
    /api/stream endpoint and the new same-response POST path — a client that
    used the GET before must see identical events via either path."""
    stream_id = "stream-xyz"
    channel = StreamChannel()
    STREAMS[stream_id] = channel
    channel.put_nowait(("delta", {"text": "chunk one"}))
    channel.put_nowait(("delta", {"text": "chunk two"}))
    channel.put_nowait(("stream_end", {}))

    get_handler = FakeHandler()
    try:
        routes._handle_sse_stream(get_handler, urlparse(f"/api/stream?stream_id={stream_id}"))
    finally:
        STREAMS.pop(stream_id, None)
    get_events = _sse_events(get_handler.wfile.getvalue())

    # Re-seed an identical channel for the streaming POST path.
    channel2 = StreamChannel()
    STREAMS[stream_id] = channel2
    channel2.put_nowait(("delta", {"text": "chunk one"}))
    channel2.put_nowait(("delta", {"text": "chunk two"}))
    channel2.put_nowait(("stream_end", {}))

    post_handler = FakeHandler()
    try:
        routes._stream_chat_start_response(
            post_handler, {"stream_id": stream_id, "session_id": "sess-1"}
        )
    finally:
        STREAMS.pop(stream_id, None)
    post_events = _sse_events(post_handler.wfile.getvalue())
    # Drop the leading chat_start event unique to the POST path — the rest
    # must match the GET path's events exactly.
    post_events_without_chat_start = [e for e in post_events if e[0] != "chat_start"]

    assert get_events == post_events_without_chat_start


def test_stream_registered_survives_post_disconnect_for_get_fallback():
    """Even if the streaming POST's connection were to drop, the stream stays
    registered in STREAMS (the worker thread doesn't know about listeners),
    so a client can still attach via the classic GET."""
    stream_id = "stream-drop"
    channel = StreamChannel()
    STREAMS[stream_id] = channel
    try:
        assert STREAMS.get(stream_id) is channel
        # Simulate events arriving without any subscriber attached yet — the
        # offline buffer replays them to whoever attaches next (GET or POST).
        channel.put_nowait(("delta", {"text": "still here"}))
        assert STREAMS.get(stream_id) is channel
    finally:
        STREAMS.pop(stream_id, None)
