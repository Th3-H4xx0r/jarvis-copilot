"""Stream time → session time.

The phone uploads only speech (its level gate drops the quiet), so a streaming
engine hears talk stitched end to end and its timestamps drift away from the
recording. Each chunk is placed at its real session time; at a gap the caller
feeds a short stretch of silence (so the engine can hear that a line ended),
and that silence maps onto the start of the gap.
"""
from __future__ import annotations

from bisect import bisect_right
from typing import List, Optional, Tuple

GAP_MS = 300
SILENCE_MS = 600
# Device stamps are whole ms while chunk lengths are exact (62.5 ms for 1000
# samples at 16 kHz); within this much a chunk is taken as following straight on.
_CONTIGUOUS_MS = 1.0


class ClockMap:
    def __init__(self) -> None:
        self._starts: List[int] = []
        self._pieces: List[Tuple[float, float, float]] = []  # (stream_start, session_start, length)
        self._stream_end = 0.0
        self._session_end: Optional[float] = None

    def place(self, n_ms: float, session_ms: Optional[float]) -> int:
        """Record `n_ms` of audio said at `session_ms`; returns ms of silence to feed first."""
        if session_ms is None:
            session_ms = self._session_end if self._session_end is not None else 0
        silence = 0
        if self._session_end is not None:
            gap = session_ms - self._session_end
            if gap >= GAP_MS:
                silence = int(min(SILENCE_MS, gap))
                self._add(silence, self._session_end)
            elif abs(gap) < _CONTIGUOUS_MS:
                session_ms = self._session_end
            elif gap < 0:
                # Older audio arriving late cannot be put back in the past of a
                # live stream; keep the stream's own timeline instead.
                session_ms = self._session_end
        self._add(n_ms, session_ms)
        self._session_end = session_ms + n_ms
        return silence

    def to_session(self, stream_ms: int) -> int:
        if not self._pieces:
            return int(stream_ms)
        index = max(0, bisect_right(self._starts, stream_ms) - 1)
        stream_start, session_start, _ = self._pieces[index]
        return int(round(session_start + (stream_ms - stream_start)))

    def _add(self, length: float, session_start: float) -> None:
        if length <= 0:
            return
        if self._pieces:
            last_stream, last_session, last_length = self._pieces[-1]
            if last_session + last_length == session_start:
                self._pieces[-1] = (last_stream, last_session, last_length + length)
                self._stream_end += length
                return
        self._pieces.append((self._stream_end, session_start, length))
        self._starts.append(self._stream_end)
        self._stream_end += length
