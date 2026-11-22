"""Local STT through faster-whisper's real audio decoder (PyAV), unmocked.

The rest of the transcription suite mocks faster-whisper. These tests run its
real decode layer on a tiny generated WAV, because that layer is where local
STT broke: PyAV 19 removed the ``metadata_errors`` keyword that
faster-whisper 1.2.1 still passes to ``av.open()``, so every local
transcription failed before the model ever ran.

Nothing here touches the network: the decode test needs no model, and the
transcription test only runs when a faster-whisper model is already cached.
"""

import math
import struct
import wave
from unittest.mock import patch

import pytest

fw_audio = pytest.importorskip("faster_whisper.audio")

SAMPLE_RATE = 16000


def _write_tone(path, seconds=1.0):
    """Write a 440 Hz mono 16-bit WAV."""
    n = int(SAMPLE_RATE * seconds)
    frames = b"".join(
        struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / SAMPLE_RATE)))
        for i in range(n)
    )
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(frames)
    return str(path)


def test_decode_audio_reads_a_wav_file(tmp_path):
    """faster-whisper's own decoder turns a WAV file into 16 kHz samples."""
    wav = _write_tone(tmp_path / "tone.wav")

    audio = fw_audio.decode_audio(wav, sampling_rate=SAMPLE_RATE)

    assert str(audio.dtype) == "float32"
    assert abs(len(audio) - SAMPLE_RATE) <= SAMPLE_RATE // 100
    assert float(abs(audio).max()) > 0.1  # the tone survived, not silence


def test_local_transcription_decodes_a_wav_file(tmp_path):
    """_transcribe_local() runs a real cached model end to end on a WAV file."""
    from faster_whisper import WhisperModel
    from faster_whisper.utils import download_model
    import tools.transcription_tools as tt

    try:
        model_dir = download_model("tiny.en", local_files_only=True)
    except Exception:
        pytest.skip("faster-whisper tiny.en model is not cached locally")

    wav = _write_tone(tmp_path / "tone.wav")
    with patch.object(
        tt, "_load_local_whisper_model",
        lambda _name: WhisperModel(model_dir, device="cpu", compute_type="int8"),
    ), patch.object(tt, "_local_model", None), patch.object(tt, "_local_model_name", None):
        result = tt._transcribe_local(wav, "tiny.en")

    assert result["success"] is True, result.get("error")
    assert result["provider"] == "local"
