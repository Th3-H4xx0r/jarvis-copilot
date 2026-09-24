"""Soniox real-time speech-to-text (placeholder until the engine lands)."""
from __future__ import annotations

from jarvis_speech.registry import register_engine


class SonioxEngine:
    name = "soniox"
    label = "Soniox"
    streams = True

    def available(self):
        return False, "not built yet"

    def transcribe_file(self, path: str) -> dict:
        return {"success": False, "transcript": "", "error": "not built yet"}

    def open_stream(self, sink, **kwargs):
        return None


register_engine("soniox", SonioxEngine)
