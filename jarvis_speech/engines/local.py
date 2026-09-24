"""Today's flow, unchanged: `tools.transcription_tools.transcribe_audio` on this server."""
from __future__ import annotations

from jarvis_speech.registry import register_engine


class LocalEngine:
    name = "local"
    label = "Current flow (this server)"
    streams = False

    def available(self):
        try:
            import tools.transcription_tools  # noqa: F401
        except Exception as exc:
            return False, f"transcription tools unavailable ({type(exc).__name__})"
        return True, ""

    def transcribe_file(self, path: str) -> dict:
        # Imported per call so a patched or swapped module is the one used.
        from tools.transcription_tools import transcribe_audio
        return transcribe_audio(path)

    def open_stream(self, sink, **kwargs):
        return None


register_engine("local", LocalEngine)
