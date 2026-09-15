"""Noise suppression for the Jarvis Pod's saved recordings.

Uses WebRTC's noise suppressor through ``webrtc-noise-gain`` (the package Home
Assistant runs on ESP32 voice satellites: 16 kHz mono, 10 ms frames). One
processor per device is kept between turns, so its noise estimate is already
warm when the next recording starts.

Only recordings are cleaned, never what is transcribed: on the pod's own clips
the suppressed audio made Whisper invent words for short or quiet turns
("Hello" became "Good morning", silence became "We'll see you tomorrow"),
while clear speech transcribed the same either way.
"""
from __future__ import annotations

import array
import sys
import threading
from typing import Optional

_FRAME_BYTES = 320           # 10 ms of 16 kHz PCM16
_SUPPRESSION_LEVEL = 3       # 0-4; 3 took the pod's fan rumble from -32 to -52 dBFS
_PEAK_TARGET = 0.7 * 32767   # about -3 dBFS
_MAX_GAIN = 4.0              # +12 dB at most, so near-silence isn't blown up

_LOCK = threading.Lock()
_PROCESSORS: dict[str, object] = {}


def available() -> bool:
    try:
        import webrtc_noise_gain  # noqa: F401
        return True
    except Exception:
        return False


def _processor(device_id: str):
    from webrtc_noise_gain import AudioProcessor

    p = _PROCESSORS.get(device_id)
    if p is None:
        p = _PROCESSORS[device_id] = AudioProcessor(0, _SUPPRESSION_LEVEL)  # no AGC: level set below
    return p


def clean(device_id: str, pcm: bytes, sample_rate: int = 16000) -> Optional[bytes]:
    """Suppressed and level-matched copy of ``pcm``, or None when it can't be cleaned."""
    if sample_rate != 16000 or len(pcm) < _FRAME_BYTES or not available():
        return None
    out = bytearray()
    with _LOCK:
        p = _processor(device_id)
        whole = len(pcm) - len(pcm) % _FRAME_BYTES
        for i in range(0, whole, _FRAME_BYTES):
            out += p.Process10ms(pcm[i:i + _FRAME_BYTES]).audio
    samples = array.array("h", bytes(out))
    if sys.byteorder != "little":
        samples.byteswap()
    peak = max((abs(v) for v in samples), default=0)
    if peak > 0:
        gain = min(_MAX_GAIN, _PEAK_TARGET / peak)
        if abs(gain - 1.0) > 0.05:
            samples = array.array("h", (max(-32768, min(32767, int(v * gain))) for v in samples))
    if sys.byteorder != "little":
        samples.byteswap()
    return samples.tobytes()
