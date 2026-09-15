"""The voice socket's opt-in Opus transport + client hint (the Jarvis Pod).

Default clients (phone, Mac) send no `codec`/`client` and must see no change.
"""
import json
import math
import pathlib
import struct
import sys
import threading

import pytest

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

import api.voice as voice  # noqa: E402
import api.voice_opus as vo  # noqa: E402

needs_opus = pytest.mark.skipif(vo.available() is not None, reason="libopus not installed")


def _state():
    return {"lock": threading.Lock(), "pcm_buf": bytearray(), "interrupt": False,
            "clarify_pending": False, "sample_rate": 16000, "session_id": ""}


def _tone(rate, ms, hz=440):
    n = rate * ms // 1000
    return b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * hz * i / rate))) for i in range(n))


def test_begin_turn_records_codec_and_client():
    st = _state()
    voice._handle_control_frame({"type": "begin_turn", "codec": "OPUS", "client": "jarvis_pod"}, st, None, None)
    assert st["codec"] == "opus"
    assert st["client"] == "jarvis_pod"


def test_begin_turn_without_codec_leaves_pcm_default():
    st = _state()
    voice._handle_control_frame({"type": "begin_turn"}, st, None, None)
    assert "codec" not in st and "client" not in st


def test_begin_turn_ignores_unknown_codec():
    st = _state()
    voice._handle_control_frame({"type": "begin_turn", "codec": "flac"}, st, None, None)
    assert "codec" not in st


def test_pod_directive_only_for_pod_client():
    plain = voice._voice_turn_directive(None)
    pod = voice._voice_turn_directive(None, "jarvis_pod")
    assert plain == voice._VOICE_REPLY_DIRECTIVE
    assert pod.startswith(plain) and "device_pod_show" in pod and "device_pod_home_save" in pod
    assert voice._voice_turn_directive(None, "mac") == plain


def test_pod_directive_keeps_heard_note():
    d = voice._voice_turn_directive("Hello there", "jarvis_pod")
    assert "Hello there" in d and "device_pod_show" in d


@needs_opus
def test_opus_round_trip_keeps_length():
    enc = vo.OpusEncoder(16000, 1)
    dec = vo.OpusDecoder(16000, 1)
    pcm = _tone(16000, 180)
    packets = enc.encode(pcm)
    assert len(packets) == 3
    out = b"".join(dec.decode(p) for p in packets)
    assert len(out) == len(pcm)


@needs_opus
def test_split_ws_message_is_reassembled_before_decode():
    st = _state()
    st["codec"] = "opus"
    packet = vo.OpusEncoder(16000, 1).encode(_tone(16000, 60))[0]
    assert voice._opus_packet_to_pcm(st, packet[:5], False) == b""
    pcm = voice._opus_packet_to_pcm(st, packet[5:], True)
    assert len(pcm) == 960 * 2


@needs_opus
def test_send_audio_opus_frames_reply(monkeypatch):
    texts, blobs = [], []
    monkeypatch.setattr(voice, "_ws_send_text", lambda c, s, t: texts.append(json.loads(t)) or True)
    monkeypatch.setattr(voice, "_ws_send_bytes", lambda c, s, b: blobs.append(b) or True)
    st = _state()
    st["codec"] = "opus"
    assert voice._send_audio(None, None, st, ("pcm", _tone(24000, 130)))
    assert texts[0] == {"type": "audio_meta", "format": "opus", "sample_rate": 24000, "frame_ms": 60}
    assert texts[-1] == {"type": "audio_end"}
    assert len(blobs) == 3  # 130 ms → three 60 ms packets (tail padded)


def test_pcm_clients_unchanged(monkeypatch):
    texts, blobs = [], []
    monkeypatch.setattr(voice, "_ws_send_text", lambda c, s, t: texts.append(json.loads(t)) or True)
    monkeypatch.setattr(voice, "_ws_send_bytes", lambda c, s, b: blobs.append(b) or True)
    assert voice._send_audio(None, None, _state(), ("pcm", b"\x00\x01" * 3840))
    assert texts[0]["format"] == "pcm_s16le"
    assert b"".join(blobs) == b"\x00\x01" * 3840


def _spec_state(pcm_len):
    import threading as _threading
    return {"lock": _threading.Lock(), "pcm_buf": bytearray(b"\x01\x00" * (pcm_len // 2)), "sample_rate": 16000}


def test_pause_hint_transcript_is_used_when_only_the_endpoint_wait_followed(monkeypatch):
    import api.voice as voice

    calls = []
    monkeypatch.setattr(voice, "_pcm_to_transcript", lambda pcm, sr, realtime=False: calls.append(len(pcm)) or "a short poem")
    state = _spec_state(64000)
    voice._start_speculative_stt(state)
    assert state["spec_stt"]["done"].wait(2)
    # 0.5 s of trailing silence arrived before end_turn: the pause-time text stands.
    assert voice._take_speculative_transcript(state, 64000 + 16000) == "a short poem"
    assert calls == [64000]
    assert "spec_stt" not in state and "spec_mark" not in state


def test_speech_after_the_pause_discards_the_speculative_transcript(monkeypatch):
    import api.voice as voice

    monkeypatch.setattr(voice, "_pcm_to_transcript", lambda pcm, sr, realtime=False: "hello")
    state = _spec_state(32000)
    voice._start_speculative_stt(state)
    assert state["spec_stt"]["done"].wait(2)
    # More than a second of audio after the pause: the user kept talking.
    assert voice._take_speculative_transcript(state, 32000 + 48000) is None

    import threading as _threading

    release = _threading.Event()
    monkeypatch.setattr(voice, "_pcm_to_transcript", lambda pcm, sr, realtime=False: release.wait(2) and "hello")
    state = _spec_state(32000)
    voice._start_speculative_stt(state)            # first pause: still transcribing...
    state["pcm_buf"].extend(b"\x01\x00" * 8000)
    voice._start_speculative_stt(state)            # ...when the user pauses again later
    release.set()
    assert voice._take_speculative_transcript(state, 48000) is None  # the first text misses the new words


def test_short_audio_starts_no_speculative_stt(monkeypatch):
    import api.voice as voice

    monkeypatch.setattr(voice, "_pcm_to_transcript", lambda *a, **k: "x")
    state = _spec_state(200)
    voice._start_speculative_stt(state)
    assert "spec_stt" not in state
    assert voice._take_speculative_transcript(state, 200) is None
