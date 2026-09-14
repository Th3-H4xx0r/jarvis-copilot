"""Opus for voice clients that can't carry raw PCM (the Jarvis Ball).

A thin ctypes binding over the system libopus (`libopus0` on Linux, `opus` from
Homebrew on macOS) — no pip dependency. Only the voice socket's opt-in
`codec: "opus"` path uses it; phone and Mac stay on PCM.

Frames are 60 ms: the ball's audio service encodes the mic at 16 kHz mono in
60 ms packets and decodes the reply at 24 kHz mono.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import threading
from typing import Optional

FRAME_MS = 60
_OPUS_APPLICATION_VOIP = 2048
_MAX_PACKET_BYTES = 1500

_lib = None
_lib_lock = threading.Lock()


class OpusUnavailable(RuntimeError):
    pass


def _load():
    global _lib
    with _lib_lock:
        if _lib is not None:
            return _lib
        names = [ctypes.util.find_library("opus"), "libopus.so.0",
                 "/opt/homebrew/lib/libopus.dylib", "/usr/local/lib/libopus.dylib"]
        for name in names:
            if not name:
                continue
            try:
                lib = ctypes.CDLL(name)
                break
            except OSError:
                continue
        else:
            raise OpusUnavailable("libopus is not installed (apt install libopus0 / brew install opus)")
        c_int, c_void_p = ctypes.c_int, ctypes.c_void_p
        lib.opus_decoder_create.restype = c_void_p
        lib.opus_decoder_create.argtypes = [ctypes.c_int32, c_int, ctypes.POINTER(c_int)]
        lib.opus_decode.restype = c_int
        lib.opus_decode.argtypes = [c_void_p, ctypes.c_char_p, ctypes.c_int32,
                                    ctypes.POINTER(ctypes.c_int16), c_int, c_int]
        lib.opus_decoder_destroy.argtypes = [c_void_p]
        lib.opus_encoder_create.restype = c_void_p
        lib.opus_encoder_create.argtypes = [ctypes.c_int32, c_int, c_int, ctypes.POINTER(c_int)]
        lib.opus_encode.restype = ctypes.c_int32
        lib.opus_encode.argtypes = [c_void_p, ctypes.POINTER(ctypes.c_int16), c_int,
                                    ctypes.c_char_p, ctypes.c_int32]
        lib.opus_encoder_destroy.argtypes = [c_void_p]
        _lib = lib
        return lib


class OpusDecoder:
    """One stream's decoder (Opus keeps state between packets)."""

    def __init__(self, sample_rate: int = 16000, channels: int = 1):
        self._lib = _load()
        err = ctypes.c_int(0)
        self._st = self._lib.opus_decoder_create(sample_rate, channels, ctypes.byref(err))
        if not self._st or err.value != 0:
            raise OpusUnavailable(f"opus_decoder_create failed ({err.value})")
        self._channels = channels
        # 120 ms is the longest Opus frame.
        self._max_samples = sample_rate * 120 // 1000
        self._buf = (ctypes.c_int16 * (self._max_samples * channels))()

    def decode(self, packet: bytes) -> bytes:
        """One packet → s16le PCM. A corrupt packet decodes to nothing."""
        n = self._lib.opus_decode(self._st, packet, len(packet), self._buf, self._max_samples, 0)
        if n <= 0:
            return b""
        return ctypes.string_at(self._buf, n * self._channels * 2)

    def __del__(self):
        st, self._st = getattr(self, "_st", None), None
        if st and getattr(self, "_lib", None):
            self._lib.opus_decoder_destroy(st)


class OpusEncoder:
    def __init__(self, sample_rate: int = 24000, channels: int = 1):
        self._lib = _load()
        err = ctypes.c_int(0)
        self._st = self._lib.opus_encoder_create(sample_rate, channels, _OPUS_APPLICATION_VOIP,
                                                 ctypes.byref(err))
        if not self._st or err.value != 0:
            raise OpusUnavailable(f"opus_encoder_create failed ({err.value})")
        self._channels = channels
        self.frame_samples = sample_rate * FRAME_MS // 1000
        self._out = ctypes.create_string_buffer(_MAX_PACKET_BYTES)

    def encode(self, pcm: bytes) -> list:
        """s16le PCM → 60 ms packets. The tail is zero-padded to a whole frame."""
        frame_bytes = self.frame_samples * self._channels * 2
        packets = []
        for i in range(0, len(pcm), frame_bytes):
            chunk = pcm[i:i + frame_bytes]
            if len(chunk) < frame_bytes:
                chunk = chunk + b"\x00" * (frame_bytes - len(chunk))
            samples = (ctypes.c_int16 * (self.frame_samples * self._channels)).from_buffer_copy(chunk)
            n = self._lib.opus_encode(self._st, samples, self.frame_samples, self._out, _MAX_PACKET_BYTES)
            if n < 0:
                raise OpusUnavailable(f"opus_encode failed ({n})")
            packets.append(self._out.raw[:n])
        return packets

    def __del__(self):
        st, self._st = getattr(self, "_st", None), None
        if st and getattr(self, "_lib", None):
            self._lib.opus_encoder_destroy(st)


def available() -> Optional[str]:
    """None when libopus loads, else the reason it doesn't."""
    try:
        _load()
        return None
    except OpusUnavailable as exc:
        return str(exc)
