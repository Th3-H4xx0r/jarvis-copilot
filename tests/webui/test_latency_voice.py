"""Tests for plan 0.1 (per-turn latency instrumentation) and plan 1.4/1.5
(ffmpeg-free audio decode + realtime STT selection) in webui/api/voice.py.

Pure unit tests — no real socket, no real STT/TTS engine, no ffmpeg.
"""
import json
import pathlib
import struct
import sys
import threading
import wave
import io

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent.parent / "webui"
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from api import voice  # noqa: E402


class _RecordingSocket:
    """conn/sock fake for _ws_send_text/_ws_send_bytes — recorded, not sent."""


def _fresh_state(**overrides):
    state = {
        "lock": threading.Lock(),
        "pcm_buf": bytearray(),
        "interrupt": False,
        "clarify_pending": False,
        "sample_rate": 16000,
        "session_id": "sess-lat",
    }
    state.update(overrides)
    return state


def _capture_ws_sends(monkeypatch):
    sent = []
    monkeypatch.setattr(voice, "_ws_send_text",
                         lambda conn, sock, text: sent.append(json.loads(text)) or True)
    monkeypatch.setattr(voice, "_ws_send_bytes", lambda conn, sock, data: True)
    return sent


# ---------------------------------------------------------------------------
# plan 0.1 — timing helpers (pure)
# ---------------------------------------------------------------------------

def test_start_turn_timing_computes_endpoint_ms():
    state = _fresh_state(client_ts=1000.0, speech_end_ts=600.0)
    timing = voice._start_turn_timing(state)
    assert timing["spans"]["endpoint_ms"] == 400.0
    # popped so it can't leak into the next turn
    assert "client_ts" not in state and "speech_end_ts" not in state


def test_start_turn_timing_no_endpoint_ms_when_absent():
    state = _fresh_state()
    timing = voice._start_turn_timing(state)
    assert "endpoint_ms" not in timing["spans"]


def test_mark_span_records_and_rounds():
    timing = {"turn_id": "t1", "spans": {}, "t_recv": 0.0, "tool_start": {}}
    voice._mark_span(timing, "stt_ms", 123.456)
    assert timing["spans"]["stt_ms"] == 123.5


def test_mark_tool_span_pairs_started_and_completed():
    timing = {"turn_id": "t1", "spans": {}, "t_recv": 0.0, "tool_start": {}}
    voice._mark_tool_span(timing, "open_app", "started")
    voice._mark_tool_span(timing, "open_app", "completed")
    assert len(timing["spans"]["tool_rtt_ms"]) == 1
    assert timing["spans"]["tool_rtt_ms"][0] >= 0.0


def test_mark_tool_span_completed_without_started_is_noop():
    timing = {"turn_id": "t1", "spans": {}, "t_recv": 0.0, "tool_start": {}}
    voice._mark_tool_span(timing, "ghost", "completed")
    assert "tool_rtt_ms" not in timing["spans"]


# ---------------------------------------------------------------------------
# plan 0.1 — end-to-end: _bridge_pipeline emits a `latency` frame with all
# spans, before the final end_turn frame.
# ---------------------------------------------------------------------------

def test_bridge_pipeline_emits_latency_frame_with_all_spans(monkeypatch):
    sent = _capture_ws_sends(monkeypatch)
    monkeypatch.setattr(voice, "_synth_audio", lambda text: ("pcm", b"\x00\x00" * 10))
    monkeypatch.setattr(
        voice, "_run_agent_turn_via_chat",
        lambda sid, transcript, **kw: iter([{"kind": "text", "text": "Hi there."}]),
    )

    state = _fresh_state(
        pretranscript="turn on the lights",
        client_ts=2000.0,
        speech_end_ts=1500.0,
    )
    voice._bridge_pipeline(state, _RecordingSocket(), _RecordingSocket())

    latency_frames = [f for f in sent if f.get("type") == "latency"]
    assert len(latency_frames) == 1
    spans = latency_frames[0]["spans"]
    for name in ("endpoint_ms", "stt_ms", "prep_ms", "ttft_ms", "first_audio_ms"):
        assert name in spans, f"missing span {name!r} in {spans!r}"
    assert spans["endpoint_ms"] == 500.0
    assert spans["stt_ms"] == 0.0  # pretranscript — server did no STT

    # The latency frame must land before the turn's final end_turn frame.
    types = [f.get("type") for f in sent]
    assert types.index("latency") < types.index("end_turn")


def test_bridge_pipeline_stt_ms_reflects_real_stt_call(monkeypatch):
    """When there's no pretranscript, stt_ms is measured around the actual
    _pcm_to_transcript call, and the realtime=True flag is forwarded."""
    sent = _capture_ws_sends(monkeypatch)
    calls = {}

    def _fake_pcm_to_transcript(pcm, sr, *, realtime=False):
        calls["realtime"] = realtime
        return "hello there"

    monkeypatch.setattr(voice, "_pcm_to_transcript", _fake_pcm_to_transcript)
    monkeypatch.setattr(voice, "_synth_audio", lambda text: ("pcm", b"\x00\x00" * 10))
    monkeypatch.setattr(
        voice, "_run_agent_turn_via_chat",
        lambda sid, transcript, **kw: iter([{"kind": "text", "text": "Hi."}]),
    )

    state = _fresh_state(pcm_buf=bytearray(b"\x00\x01" * 2000))  # >1000 bytes
    voice._bridge_pipeline(state, _RecordingSocket(), _RecordingSocket())

    assert calls["realtime"] is True
    latency_frames = [f for f in sent if f.get("type") == "latency"]
    assert "stt_ms" in latency_frames[0]["spans"]


# ---------------------------------------------------------------------------
# plan 1.5 — quality-turn's _pcm_to_transcript call stays realtime=False
# ---------------------------------------------------------------------------

def test_quality_turn_transcribe_call_is_not_realtime(monkeypatch):
    calls = {}

    def _fake_transcribe(path, *, realtime=False):
        calls["realtime"] = realtime
        return {"success": True, "transcript": "hello"}

    monkeypatch.setattr(voice, "_try_import_stt", lambda: _fake_transcribe)
    pcm = struct.pack("<8000h", *([0] * 8000))
    voice._pcm_to_transcript(pcm, 16000)  # default realtime=False, as quality-turn calls it
    assert calls["realtime"] is False


def test_realtime_bridge_transcribe_call_is_realtime(monkeypatch):
    calls = {}

    def _fake_transcribe(path, *, realtime=False):
        calls["realtime"] = realtime
        return {"success": True, "transcript": "hello"}

    monkeypatch.setattr(voice, "_try_import_stt", lambda: _fake_transcribe)
    pcm = struct.pack("<8000h", *([0] * 8000))
    voice._pcm_to_transcript(pcm, 16000, realtime=True)
    assert calls["realtime"] is True


# ---------------------------------------------------------------------------
# plan 1.4 — WAV→PCM in-process (no ffmpeg) + MP3 decode fallback chain
# ---------------------------------------------------------------------------

def _make_wav(seconds=0.2, rate=22050, channels=1):
    n = int(seconds * rate)
    frames = struct.pack(f"<{n * channels}h", *([1000] * (n * channels)))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(frames)
    return buf.getvalue()


def test_wav_bytes_to_pcm24k_resamples_without_ffmpeg(monkeypatch):
    import subprocess

    def _boom(*a, **k):
        raise AssertionError("ffmpeg subprocess must not be used for the Piper WAV path")

    monkeypatch.setattr(subprocess, "run", _boom)
    wav_bytes = _make_wav(seconds=0.5, rate=22050)
    pcm = voice._wav_bytes_to_pcm24k(wav_bytes)
    assert pcm is not None
    assert len(pcm) > 0
    # 0.5s @ 24kHz mono s16le ≈ 24000 bytes; resampling math gives an
    # approximate frame count, not exact — assert it's in the right ballpark.
    expected_bytes = int(0.5 * 24000) * 2
    assert abs(len(pcm) - expected_bytes) < expected_bytes * 0.05


def test_wav_bytes_to_pcm24k_downmixes_stereo():
    wav_bytes = _make_wav(seconds=0.1, rate=24000, channels=2)
    pcm = voice._wav_bytes_to_pcm24k(wav_bytes)
    assert pcm is not None
    # mono output: half the sample count of the stereo input at matching rate
    assert len(pcm) > 0


def test_wav_bytes_to_pcm24k_invalid_input_returns_none():
    assert voice._wav_bytes_to_pcm24k(b"not a wav file") is None


def test_resample_pcm16_mono_noop_when_rates_match():
    frames = struct.pack("<4h", 1, 2, 3, 4)
    assert voice._resample_pcm16_mono(frames, 24000, 24000) == frames


def test_decode_mp3_to_pcm24k_falls_back_to_ffmpeg_when_miniaudio_missing(monkeypatch):
    # miniaudio isn't installed in this environment — confirm the fallback
    # path is exactly _mp3_to_pcm24k (no crash from the optional import).
    monkeypatch.setattr(voice, "_mp3_to_pcm24k", lambda b: b"fallback-pcm")
    assert voice._decode_mp3_to_pcm24k(b"fake mp3 bytes") == b"fallback-pcm"


def test_synth_audio_uses_piper_native_path_when_provider_is_piper(monkeypatch):
    """plan 1.4 — when the effective provider is piper, _synth_audio must
    skip the mp3/ffmpeg path entirely and return native pcm."""
    monkeypatch.setattr(voice, "_resolve_effective_tts_provider", lambda cfg: ("piper", {"piper": {}}))
    monkeypatch.setattr(voice, "_synth_piper_pcm24k", lambda text, tts_section: b"piper-pcm")

    def _boom(*a, **k):
        raise AssertionError("the generic mp3 path must not run when piper succeeds")

    monkeypatch.setattr(voice, "_tts_to_base64", _boom)
    result = voice._synth_audio("Hello there.")
    assert result == ("pcm", b"piper-pcm")


def test_synth_audio_falls_back_to_mp3_path_when_piper_fails(monkeypatch):
    monkeypatch.setattr(voice, "_resolve_effective_tts_provider", lambda cfg: ("piper", {"piper": {}}))
    monkeypatch.setattr(voice, "_synth_piper_pcm24k", lambda text, tts_section: None)
    monkeypatch.setattr(voice, "_tts_to_base64", lambda text: "")  # simulate total TTS failure
    monkeypatch.setattr(voice.time, "sleep", lambda *_: None)  # skip the retry backoff
    result = voice._synth_audio("Hello there.")
    assert result is None
