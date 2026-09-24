"""The Soniox engine against a scripted connection — no network."""
import json
import threading
import time

from jarvis_speech.engines import soniox
from tests.jarvis_speech.test_assemble import Rec, tok


class FakeTransport:
    """Scripted Soniox: answers the end-of-audio frame with `script`, then `finished`.

    Like the real server (seen live 2026-09-24), only an empty TEXT frame ends the
    audio; an empty binary frame is zero bytes of audio and Soniox keeps waiting.
    """

    def __init__(self, script):
        self.sent, self.script, self._q, self.closed = [], list(script), [], False
        self._cv = threading.Condition()

    def send(self, data):
        self.sent.append(data)
        if data == "":
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
    # On for Voice too: Soniox hearing the end of an utterance ends the turn.
    assert config_msg["enable_endpoint_detection"] is True and "translation" not in config_msg
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


def test_voice_leans_english_when_no_languages_are_set(monkeypatch):
    # With nothing to lean on, a short unclear Pod turn came back as Slovak
    # ("Na konkrétny moment.") or Indonesian. A hint is soft: other languages
    # still come through.
    son = dict(soniox.config.DEFAULTS["soniox"], language_hints=[])
    monkeypatch.setattr(soniox.config, "load", lambda: {"surfaces": {}, "soniox": son})
    for purpose, hints in (("voice", ["en"]), ("live", None)):
        t = FakeTransport([])
        _engine(monkeypatch, t).open_stream(Rec(), rate=16000, purpose=purpose).finish(timeout=2)
        assert json.loads(t.sent[0]).get("language_hints") == hints


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
        if data == "":
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


# ── bug sweep ──────────────────────────────────────────────────────────────


def test_audio_fed_faster_than_real_time_is_never_dropped(monkeypatch):
    t = FakeTransport([])
    gate = threading.Event()
    eng = _engine(monkeypatch, t)
    eng._connect = lambda: (gate.wait(2), t)[1]
    s = eng.open_stream(Rec(), rate=16000, purpose="file")
    for _ in range(2000):
        s.feed(b"\x00\x00" * 320)
    gate.set()
    s.finish(timeout=5)
    assert _audio_bytes(t) == 2000 * 640 and not s.error


def test_close_during_connect_closes_the_socket(monkeypatch):
    t = FakeTransport([])
    gate = threading.Event()
    eng = _engine(monkeypatch, t)
    eng._connect = lambda: (gate.wait(2), t)[1]
    s = eng.open_stream(Rec(), rate=16000, purpose="voice")
    s.close()
    gate.set()
    deadline = time.time() + 3
    while not t.closed and time.time() < deadline:
        time.sleep(0.02)
    assert t.closed


def test_an_idle_close_answered_without_finished_is_not_a_failure(monkeypatch):
    t = ClosesWithoutFinished([{"tokens": [tok("bye now", 0, 400)]}])
    rec = Rec()
    s = _engine(monkeypatch, t).open_stream(rec, rate=16000, purpose="live", idle_close_s=0.2)
    s.feed(b"\x00\x01" * 1600, ts_ms=0)
    deadline = time.time() + 3
    while not s.done and time.time() < deadline:
        time.sleep(0.02)
    assert s.done and s.error == "" and rec.errors == []
    assert [x.text for x in rec.segs] == ["bye now"]


def test_odd_sized_chunks_do_not_drift(monkeypatch):
    t = FakeTransport([{"tokens": [tok("end", 3_599_000, 3_600_000), tok("<end>")]}])
    rec = Rec()
    s = _engine(monkeypatch, t).open_stream(rec, rate=16000, purpose="live")
    for k in range(57_600):             # one hour of 1000-sample (62.5 ms) chunks, device-stamped
        s.feed(b"\x00\x00" * 1000, ts_ms=int(k * 62.5))
    s.finish(timeout=30)
    assert abs(rec.segs[0].end_ms - 3_600_000) <= 1


def test_a_close_before_finished_marks_the_result_cut_off(monkeypatch):
    t = ClosesWithoutFinished([{"tokens": [tok("half a", 0, 400)]}])
    s = _engine(monkeypatch, t).open_stream(Rec(), rate=16000, purpose="voice")
    s.feed(b"\x00\x01" * 1600)
    assert [x.text for x in s.finish(timeout=2)] == ["half a"]
    assert s.cut_off and s.error == ""


def test_a_cut_off_file_is_not_a_success(monkeypatch, tmp_path):
    t = ClosesWithoutFinished([{"tokens": [tok("half a", 0, 400)]}])
    path = tmp_path / "note.ogg"
    path.write_bytes(b"OggS" + b"\x00" * 5000)
    assert _engine(monkeypatch, t).transcribe_file(str(path))["success"] is False


def test_end_of_audio_is_an_empty_text_frame(monkeypatch):
    t = FakeTransport([])
    s = _engine(monkeypatch, t).open_stream(Rec(), rate=16000, purpose="voice")
    s.feed(b"\x00\x01" * 160)
    s.finish(timeout=2)
    assert s.error == "" and isinstance(t.sent[-1], str) and t.sent[-1] == ""


def test_check_can_try_a_key_that_is_not_saved(monkeypatch):
    t = FakeTransport([])
    monkeypatch.setattr(soniox.keys, "soniox_key", lambda: "")
    eng = soniox.SonioxEngine()
    eng._connect = lambda: t
    assert eng.check(key="typed-key-5678") == (True, "Soniox answered")
    assert json.loads(t.sent[0])["api_key"] == "typed-key-5678"


def test_connect_turns_off_the_library_ping(monkeypatch):
    # Soniox reads audio at about real time, so a ping sent behind a backlog waits
    # behind it: 120 s fed at once had the library close a healthy stream at ~40 s
    # (1011 keepalive ping timeout) and the rest of the words were lost.
    import websockets.sync.client as client
    seen = {}
    monkeypatch.setattr(client, "connect", lambda url, **kw: seen.update(kw) or object())
    soniox.SonioxEngine()._connect()
    assert seen["ping_interval"] is None


class NeverAnswers(FakeTransport):
    """The socket stays open but Soniox never says anything back."""

    def send(self, data):
        self.sent.append(data)


def test_audio_nobody_answers_fails_the_stream(monkeypatch):
    monkeypatch.setattr(soniox, "_STALL_S", 0.5)
    rec = Rec()
    s = _engine(monkeypatch, NeverAnswers([])).open_stream(rec, rate=16000, purpose="live")
    s.feed(b"\x00\x01" * 1600)
    deadline = time.monotonic() + 5
    while not s.done and time.monotonic() < deadline:
        time.sleep(0.05)
    assert s.error == "Soniox stopped answering"


def test_a_quiet_stream_with_no_audio_is_not_a_stall(monkeypatch):
    monkeypatch.setattr(soniox, "_STALL_S", 0.3)
    s = _engine(monkeypatch, NeverAnswers([])).open_stream(Rec(), rate=16000, purpose="live")
    time.sleep(1.0)
    assert not s.done and s.error == ""
    s.close()
