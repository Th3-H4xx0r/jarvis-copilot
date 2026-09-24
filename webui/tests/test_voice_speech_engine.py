"""Voice (phone, Mac, web, Jarvis Pod) through the configured speech engine.

On the default engine nothing changes. With a streaming engine each turn's audio
streams as it arrives and the words are ready at end_turn; any failure answers
the same turn from its own buffered audio on the local path.
"""
import base64
import io
import json
import pathlib
import sys
import threading

import pytest
import yaml

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

import api.voice as voice  # noqa: E402
from jarvis_speech.types import Segment  # noqa: E402


class FakeStream:
    def __init__(self, segments=None, error=""):
        self.fed, self.segments, self.error = [], list(segments or []), error
        self.closed = self.finished = False

    def feed(self, pcm, ts_ms=None):
        self.fed.append(pcm)
        return True

    def finish(self, timeout=5.0):
        self.finished = True
        return [] if self.error else list(self.segments)

    def close(self):
        self.closed = True


class FakeEngine:
    name, label, streams = "fake", "Fake", True

    def __init__(self, make=FakeStream):
        self.opened, self._make = [], make

    def open_stream(self, sink, *, rate, translate_to="", purpose="live", idle_close_s=0):
        stream = self._make()
        self.opened.append((rate, purpose, stream))
        return stream


def _state(**extra):
    state = {"lock": threading.Lock(), "pcm_buf": bytearray(), "interrupt": False,
             "clarify_pending": False, "sample_rate": 16000, "session_id": ""}
    state.update(extra)
    return state


@pytest.fixture
def sent(monkeypatch):
    frames = []
    monkeypatch.setattr(voice, "_ws_send_text", lambda c, s, t: frames.append(json.loads(t)) or True)
    monkeypatch.setattr(voice, "_generate_reply", lambda text: "")
    return frames


def _no_local_stt(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("the local path must not run")
    monkeypatch.setattr(voice, "_pcm_to_transcript", boom)


def test_default_local_never_opens_a_stream(tmp_path, monkeypatch):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(yaml.safe_dump({"model": {"default": "m"}}))
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    state = _state()
    with state["lock"]:
        voice._feed_turn_stream(state, b"\x01\x00" * 160)
    assert "stt_stream" not in state


def test_frames_feed_one_stream_per_turn(monkeypatch):
    engine = FakeEngine()
    monkeypatch.setattr(voice, "_voice_engine", lambda: engine)
    state = _state(sample_rate=24000)
    with state["lock"]:
        voice._feed_turn_stream(state, b"a" * 320)
        voice._feed_turn_stream(state, b"b" * 320)
    assert len(engine.opened) == 1
    rate, purpose, stream = engine.opened[0]
    assert (rate, purpose, stream.fed) == (24000, "voice", [b"a" * 320, b"b" * 320])
    with state["lock"]:
        assert voice._take_turn_stream(state) is stream
        voice._feed_turn_stream(state, b"c" * 320)
    assert len(engine.opened) == 2


def test_engine_that_cannot_open_is_not_retried_every_frame(monkeypatch):
    calls = []

    class Refuses(FakeEngine):
        def open_stream(self, sink, **kw):
            calls.append(1)
            return None
    monkeypatch.setattr(voice, "_voice_engine", lambda: Refuses())
    state = _state()
    with state["lock"]:
        voice._feed_turn_stream(state, b"a" * 320)
        voice._feed_turn_stream(state, b"b" * 320)
    assert calls == [1] and "stt_stream" not in state


def test_on_device_text_turn_opens_no_stream(monkeypatch):
    engine = FakeEngine()
    monkeypatch.setattr(voice, "_voice_engine", lambda: engine)
    state = _state(pretranscript="already heard")
    with state["lock"]:
        voice._feed_turn_stream(state, b"a" * 320)
    assert engine.opened == []


def test_begin_turn_abandons_the_open_stream():
    stream = FakeStream()
    state = _state(stt_stream=stream)
    voice._handle_control_frame({"type": "begin_turn"}, state, None, None)
    assert stream.closed and "stt_stream" not in state


def test_speculative_pass_skipped_while_engine_streams(monkeypatch):
    monkeypatch.setattr(voice, "_pcm_to_transcript_fast",
                        lambda *a: (_ for _ in ()).throw(AssertionError("no second pass")))
    state = _state(stt_stream=FakeStream())
    state["pcm_buf"] += b"\x01\x00" * 4000
    voice._start_speculative_stt(state)
    assert "spec_stt" not in state


def test_bridge_uses_engine_transcript(monkeypatch, sent):
    _no_local_stt(monkeypatch)
    state = _state(stt_stream=FakeStream([Segment("turn off", 0, 400), Segment("the lights", 400, 900)]))
    state["pcm_buf"] += b"\x01\x00" * 8000
    voice._bridge_pipeline(state, None, None)
    assert {"type": "transcript", "text": "turn off the lights", "is_final": True} in sent
    assert "stt_stream" not in state


def test_voice_turn_falls_back_when_stream_errors(monkeypatch, sent):
    calls = []
    monkeypatch.setattr(voice, "_pcm_to_transcript",
                        lambda pcm, sr, *, realtime=False: calls.append((pcm, sr, realtime)) or "local words")
    pcm = b"\x01\x00" * 8000
    state = _state(stt_stream=FakeStream(error="insufficient_balance: out of credit"))
    state["pcm_buf"] += pcm
    voice._bridge_pipeline(state, None, None)
    assert calls == [(pcm, 16000, True)]
    assert [m for m in sent if m.get("type") == "transcript"] == [
        {"type": "transcript", "text": "local words", "is_final": True}]


def test_nothing_back_for_a_long_turn_is_not_trusted(monkeypatch, sent):
    calls = []
    monkeypatch.setattr(voice, "_pcm_to_transcript",
                        lambda pcm, sr, *, realtime=False: calls.append(1) or "local words")
    state = _state(stt_stream=FakeStream([]))
    state["pcm_buf"] += b"\x01\x00" * 16000  # one second
    voice._bridge_pipeline(state, None, None)
    assert calls == [1]


def test_pod_turn_on_engine_still_records(monkeypatch, sent):
    _no_local_stt(monkeypatch)
    recorded = []
    monkeypatch.setattr(voice, "_record_pod_turn",
                        lambda state, pcm, sr, transcript: recorded.append((len(pcm), sr, transcript)))
    state = _state(client="jarvis_pod", stt_stream=FakeStream([Segment("what time is it", 0, 900)]))
    state["pcm_buf"] += b"\x01\x00" * 8000
    voice._bridge_pipeline(state, None, None)
    assert recorded == [(16000, 16000, "what time is it")]


def test_clarify_answer_uses_engine_transcript(monkeypatch, sent):
    _no_local_stt(monkeypatch)
    seen = {}
    monkeypatch.setattr(voice, "_stream_segments", lambda c, s, st, g, timing=None: True)
    monkeypatch.setattr(voice, "_run_agent_continuation_after_clarify",
                        lambda sid, text: seen.setdefault("text", text) or iter(()))
    state = _state(session_id="s", clarify_pending=True, stt_stream=FakeStream([Segment("the first one", 0, 600)]))
    state["pcm_buf"] += b"\x01\x00" * 8000
    voice._bridge_answer_clarify(state, None, None)
    assert seen["text"] == "the first one"


def test_engine_transcribes_a_whole_clip(monkeypatch):
    engine = FakeEngine(lambda: FakeStream([Segment("hello there", 0, 500)]))
    monkeypatch.setattr(voice, "_voice_engine", lambda: engine)
    pcm = b"\x01\x00" * 16000
    assert voice._engine_transcribe_pcm(pcm, 16000) == "hello there"
    assert b"".join(engine.opened[0][2].fed) == pcm


def test_no_engine_means_no_clip_transcript(monkeypatch):
    monkeypatch.setattr(voice, "_voice_engine", lambda: None)
    assert voice._engine_transcribe_pcm(b"\x01\x00" * 16000, 16000) is None


def test_quality_turn_uses_engine_before_local(monkeypatch):
    seen = {}
    monkeypatch.setattr(voice, "_run_agent_turn_via_chat",
                        lambda sid, text, **kw: seen.setdefault("text", text) or iter(()))
    monkeypatch.setattr(voice, "_engine_transcribe_pcm", lambda pcm, sr: "engine words")
    _no_local_stt(monkeypatch)

    class Handler:
        status, written = None, b""
        wfile = property(lambda self: self)
        def send_response(self, status): self.status = status
        def send_header(self, *a): pass
        def end_headers(self): pass
        def write(self, data): self.written += data
        def flush(self): pass
    voice._voice_quality_turn(Handler(), {"audio_base64": base64.b64encode(b"x" * 2000).decode(),
                                          "session_id": "s"})
    assert seen["text"] == "engine words"


def test_upload_endpoint_routes_through_adapter(monkeypatch):
    import jarvis_speech
    from api.upload import handle_transcribe

    class Cloud:
        name = "cloud"

        def transcribe_file(self, path):
            return {"success": True, "transcript": "cloud words", "provider": "cloud"}
    monkeypatch.setattr(jarvis_speech, "engine_for", lambda surface: Cloud() if surface == "upload" else None)
    boundary = b"b0undary"
    body = (b"--" + boundary + b"\r\nContent-Disposition: form-data; name=\"file\"; filename=\"v.webm\"\r\n"
            b"Content-Type: audio/webm\r\n\r\nRIFFfake\r\n--" + boundary + b"--\r\n")

    class Handler:
        def __init__(self):
            self.rfile, self.wfile = io.BytesIO(body), io.BytesIO()
            self.headers = {"Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
                            "Content-Length": str(len(body))}
            self.status = None
        def send_response(self, status): self.status = status
        def send_header(self, *a): pass
        def end_headers(self): pass
    handler = Handler()
    handle_transcribe(handler)
    assert handler.status == 200
    assert json.loads(handler.wfile.getvalue()) == {"ok": True, "transcript": "cloud words"}
