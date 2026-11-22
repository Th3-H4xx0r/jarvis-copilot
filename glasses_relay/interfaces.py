"""Dependency-injection interfaces for the standalone glasses relay.

Three tiny callable protocols let the relay server stay agnostic about *how*
mic audio becomes text, text becomes an answer, and an answer becomes audio:

    Transcriber   16 kHz mono PCM16 bytes -> transcript text
    Brain         transcript text         -> spoken reply text
    Synthesizer   reply text              -> 16 kHz mono PCM16 bytes

Audio everywhere is 16 kHz mono signed-16-bit little-endian PCM (the format the
Meta glasses relay speaks on the wire). The real defaults live in
``glasses_relay.backends`` and lazy-load their heavy dependencies, so importing
this package never pulls in faster-whisper or a TTS engine; tests inject fakes
that return fixed values with no models, network, or API keys.
"""
from __future__ import annotations

from typing import Protocol, runtime_checkable


@runtime_checkable
class Transcriber(Protocol):
    """Turn buffered mic audio into a transcript (``""`` = nothing intelligible)."""

    def __call__(self, pcm16: bytes) -> str:  # pragma: no cover - protocol
        ...


@runtime_checkable
class Brain(Protocol):
    """Turn a user transcript into a short spoken reply."""

    def __call__(self, transcript: str) -> str:  # pragma: no cover - protocol
        ...


@runtime_checkable
class Synthesizer(Protocol):
    """Turn reply text into 16 kHz mono PCM16 audio bytes."""

    def __call__(self, text: str) -> bytes:  # pragma: no cover - protocol
        ...
