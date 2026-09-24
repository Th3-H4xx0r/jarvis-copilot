"""The Soniox engine against a scripted connection — no network."""
import json
import threading
import time

from jarvis_speech.engines import soniox
from tests.jarvis_speech.test_assemble import Rec, tok


class FakeTransport:
    """Scripted Soniox: answers the end-of-audio frame with `script`, then `finished`."""

    def __init__(self, script):
        self.sent, self.script, self._q, self.closed = [], list(script), [], False
        self._cv = threading.Condition()

    def send(self, data):
        self.sent.append(data)
        if data in (b"", ""):
            with self._cv:
                self._q += [json.dumps(r) for r in self.script] + [json.dumps({"tokens": [], "finished": True})]
                self._cv.notify_all()

    def recv(self, timeout=None):
        with self._cv:
            self._cv.wait_for(lambda: self._q or self.closed, timeout=timeout)
            if self._q:
                return self._q.pop(0)
            if self.closed:
                raise EOFError
            raise TimeoutError

    def close(self):
        with self._cv:
            self.closed = True
            self._cv.notify_all()


def _engine(monkeypatch, transport):
    monkeypatch.setattr(soniox.keys, "soniox_key", lambda: "k-test-1234")
    eng = soniox.SonioxEngine()
    eng._connect = lambda: transport
    return eng


def _audio_bytes(t):
    return sum(len(m) for m in t.sent[1:] if isinstance(m, (bytes, bytearray)))


def test_voice_stream_returns_final_text(monkeypatch):
    t = FakeTransport([{"tokens": [tok("turn", 0, 200), tok(" off the lights", 200, 900)]}])
    stream = _engine(monkeypatch, t).open_stream(Rec(), rate=16000, purpose="voice")
    stream.feed(b"\x00\x01" * 1600)
    segs = stream.finish(timeout=2)
    assert " ".join(s.text for s in segs) == "turn off the lights"
    config_msg = json.loads(t.sent[0])
    assert config_msg["audio_format"] == "pcm_s16le" and config_msg["sample_rate"] == 16000
    assert config_msg["num_channels"] == 1 and config_msg["model"] == "stt-rt-v5"
    assert config_msg["enable_endpoint_detection"] is False and "translation" not in config_msg
    assert config_msg["api_key"] == "k-test-1234"
    assert _audio_bytes(t) == 3200


def test_live_config_carries_settings_and_translation(monkeypatch):
    son = dict(soniox.config.DEFAULTS["soniox"], custom_words=["Jarvis"], language_hints=["en", "es"])
    monkeypatch.setattr(soniox.config, "load", lambda: {"surfaces": {}, "soniox": son})
    t = FakeTransport([])
    stream = _engine(monkeypatch, t).open_stream(Rec(), rate=16000, translate_to="en", purpose="live")
    stream.finish(timeout=2)
    msg = json.loads(t.sent[0])
    assert msg["translation"] == {"type": "one_way", "target_language": "en"}
    assert msg["context"]["terms"] == ["Jarvis"] and msg["language_hints"] == ["en", "es"]
    assert msg["enable_endpoint_detection"] is True and msg["endpoint_latency_adjustment_level"] == 2
    assert msg["enable_speaker_diarization"] is True and msg["enable_language_identification"] is True


def test_connect_failure_reports_error_and_finish_is_empty(monkeypatch):
    rec = Rec()
    eng = _engine(monkeypatch, None)

    def boom():
        raise ConnectionRefusedError("refused")
    eng._connect = boom
    stream = eng.open_stream(rec, rate=16000, purpose="voice")
    stream.feed(b"\x00" * 3200)
    assert stream.finish(timeout=2) == [] and stream.error and rec.errors


def test_error_frame_ends_stream_with_error(monkeypatch):
    t = FakeTransport([{"tokens": [], "error_code": 402, "error_type": "insufficient_balance",
                        "error_message": "out of credit"}])
    rec = Rec()
    stream = _engine(monkeypatch, t).open_stream(rec, rate=16000, purpose="voice")
    stream.feed(b"\x00\x01" * 1600)
    assert stream.finish(timeout=2) == []
    assert "insufficient_balance" in stream.error and stream.done


def test_key_never_in_error_or_logs(monkeypatch, caplog):
    rec = Rec()
    eng = _engine(monkeypatch, None)

    def boom():
        raise RuntimeError("k-test-1234 rejected")  # a library echoing the key back
    eng._connect = boom
    s = eng.open_stream(rec, rate=16000, purpose="voice")
    s.finish(timeout=2)
    assert "k-test-1234" not in (s.error or "") and all("k-test-1234" not in e for e in rec.errors)
    assert "k-test-1234" not in caplog.text


def test_feed_after_finish_is_refused(monkeypatch):
    t = FakeTransport([])
    s = _engine(monkeypatch, t).open_stream(Rec(), rate=16000, purpose="voice")
    s.finish(timeout=2)
    assert s.feed(b"\x00\x00" * 160) is False


def test_idle_close_ends_stream_and_flushes(monkeypatch):
    t = FakeTransport([{"tokens": [tok("bye", 0, 200)]}])
    rec = Rec()
    s = _engine(monkeypatch, t).open_stream(rec, rate=16000, purpose="live", idle_close_s=0.2)
    s.feed(b"\x00\x01" * 1600, ts_ms=0)
    deadline = time.time() + 3
    while not s.done and time.time() < deadline:
        time.sleep(0.02)
    assert s.done and [x.text for x in rec.segs] == ["bye"]


def test_live_gap_feeds_silence_and_maps_times(monkeypatch):
    t = FakeTransport([{"tokens": [tok("later", 1700, 1900), tok("<end>")]}])
    rec = Rec()
    s = _engine(monkeypatch, t).open_stream(rec, rate=16000, purpose="live")
    s.feed(b"\x00\x00" * 16000, ts_ms=0)    # 1000 ms at session 0
    s.feed(b"\x00\x00" * 1600, ts_ms=5000)  # 100 ms at session 5000 → 600 ms of silence first
    s.finish(timeout=2)
    assert _audio_bytes(t) == (16000 + 9600 + 1600) * 2
    assert rec.segs[0].start_ms == 5100     # stream 1700 → 5000 + (1700 - 1600)


class ClosesWithoutFinished(FakeTransport):
    """Answers the end frame with final words, then drops the socket — no `finished`."""

    def send(self, data):
        self.sent.append(data)
        if data in (b"", ""):
            with self._cv:
                self._q += [json.dumps(r) for r in self.script]
                self._cv.notify_all()
            threading.Timer(0.1, self.close).start()


def test_words_before_an_unfinished_close_are_kept(monkeypatch):
    t = ClosesWithoutFinished([{"tokens": [tok("last", 0, 200), tok(" words", 200, 500)]}])
    s = _engine(monkeypatch, t).open_stream(Rec(), rate=16000, purpose="voice")
    s.feed(b"\x00\x01" * 1600)
    assert [x.text for x in s.finish(timeout=2)] == ["last words"]
    assert s.error == ""


def test_available_needs_a_key(monkeypatch):
    monkeypatch.setattr(soniox.keys, "soniox_key", lambda: "")
    ok, reason = soniox.SonioxEngine().available()
    assert ok is False and "SONIOX_API_KEY" in reason


def test_file_in_a_container_goes_up_as_is(monkeypatch, tmp_path):
    t = FakeTransport([{"tokens": [tok("voice", 0, 300, lang="en"), tok(" note", 300, 600, lang="en")]}])
    path = tmp_path / "note.ogg"
    path.write_bytes(b"OggS" + b"\x00" * 5000)
    result = _engine(monkeypatch, t).transcribe_file(str(path))
    assert result == {"success": True, "transcript": "voice note", "provider": "soniox",
                      "language": "en", "translation": ""}
    assert json.loads(t.sent[0])["audio_format"] == "auto"
    assert _audio_bytes(t) == 5004


def test_file_error_is_unsuccessful(monkeypatch, tmp_path):
    eng = _engine(monkeypatch, None)

    def boom():
        raise ConnectionRefusedError("refused")
    eng._connect = boom
    path = tmp_path / "note.webm"
    path.write_bytes(b"\x1aE\xdf\xa3" + b"\x00" * 100)
    result = eng.transcribe_file(str(path))
    assert result["success"] is False and result["error"]


def test_languages_table_has_codes_and_names():
    codes = {row["code"] for row in soniox.LANGUAGES}
    assert {"en", "es", "zh", "te"} <= codes and all(row["name"] for row in soniox.LANGUAGES)
