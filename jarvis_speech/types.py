"""The shapes every speech engine speaks."""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Protocol, Tuple


@dataclass(frozen=True)
class Segment:
    """One finished line: its words, when it was said, and by whom."""
    text: str
    start_ms: int
    end_ms: int
    language: str = ""
    translation: str = ""
    speaker: str = ""
    # Ties a translation that arrives after the line closed back to this line.
    key: int = 0


class Sink(Protocol):
    """Where a stream reports. Called from the stream's own thread."""
    def on_partial(self, text: str, start_ms: int, speaker: str, language: str) -> None: ...
    def on_segment(self, segment: Segment) -> None: ...
    def on_translation(self, key: int, text: str) -> None: ...
    def on_error(self, message: str) -> None: ...


class Stream(Protocol):
    done: bool
    error: str

    def feed(self, pcm16: bytes, ts_ms: Optional[int] = None) -> None:
        """Queue audio. Never blocks. `ts_ms` is session time when the caller has it."""

    def finish(self, timeout: float = 5.0) -> List[Segment]:
        """Finalize what was fed, wait up to `timeout`, and return every segment."""

    def close(self) -> None:
        """Abandon the stream without waiting for its words."""


class Engine(Protocol):
    name: str
    label: str
    streams: bool

    def available(self) -> Tuple[bool, str]:
        """Whether it can run right now (no network), and why not."""

    def transcribe_file(self, path: str) -> dict:
        """`transcribe_audio`'s dict shape: success, transcript, error, provider."""

    def open_stream(self, sink: Sink, *, rate: int, translate_to: str = "",
                    purpose: str = "live", idle_close_s: float = 0) -> Optional[Stream]:
        """A live stream, or None when this engine cannot stream."""
