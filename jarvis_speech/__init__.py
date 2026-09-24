"""One door for turning speech into text, whichever engine is configured.

Callers ask `engine_for(surface)`. `None` means "today's path" — the caller runs
exactly what it ran before this package existed — so an unset, unknown or
unusable engine can never take a voice turn, an upload or a Live session down.
"""
from __future__ import annotations

import logging
from typing import Any, Dict

from jarvis_speech import config, registry

logger = logging.getLogger(__name__)
# At DEBUG the websockets library logs every frame, the first of which carries the key.
logging.getLogger("websockets").setLevel(logging.WARNING)

_TODAYS_PATH = ("local", config.EDGE, "")


def engine_for(surface: str):
    """The engine to use for `surface`, or None for today's path."""
    try:
        name = config.load()["surfaces"].get(surface, "")
        if name in _TODAYS_PATH:
            return None
        engine = registry.get(name)
        if engine is None:
            logger.warning("speech: %s is set to unknown engine %r; using today's path", surface, name)
            return None
        ok, reason = engine.available()
        if not ok:
            logger.warning("speech: %s engine %s unavailable (%s); using today's path",
                           surface, name, reason)
            return None
        return engine
    except Exception:
        logger.warning("speech: could not choose an engine for %s", surface, exc_info=True)
        return None


def transcribe_file(path: str, *, surface: str = "upload") -> Dict[str, Any]:
    """`transcribe_audio`'s contract, through the configured engine, falling back to it."""
    engine = engine_for(surface)
    if engine is not None:
        try:
            result = engine.transcribe_file(path)
        except Exception as exc:
            result = {"success": False, "transcript": "", "error": type(exc).__name__}
        if isinstance(result, dict) and result.get("success"):
            return result
        logger.warning("speech: %s failed for %s (%s); using the local engine", engine.name, surface,
                       result.get("error") if isinstance(result, dict) else "no result")
    from tools.transcription_tools import transcribe_audio
    return transcribe_audio(path)
