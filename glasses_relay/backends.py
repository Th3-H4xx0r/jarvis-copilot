"""Real default STT / brain / TTS backends for the glasses relay.

Each backend is a small callable implementing one of the protocols in
``glasses_relay.interfaces``. Every heavy dependency (faster-whisper, the
auxiliary LLM client, the TTS tool) is imported lazily on first use, so
importing this module stays cheap and the fake-injected test path never
touches a model, the network, or an API key.

Transient audio is written under a per-profile scratch directory resolved via
``get_hermes_home()`` so each JarvisCopilot profile keeps its own state.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Optional

from jarviscopilot_constants import get_hermes_home

from .config import RATE

logger = logging.getLogger("glasses_relay")

# Buffers shorter than this (~100 ms) are treated as "nothing said" before we
# even bother spinning up the STT model.
MIN_PCM_BYTES = 3_200


def _relay_scratch_dir() -> Path:
    """Per-profile scratch dir for transient relay audio (profile-safe)."""
    d = get_hermes_home() / "cache" / "glasses_relay"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _mktemp(suffix: str) -> str:
    fd, path = tempfile.mkstemp(suffix=suffix, dir=str(_relay_scratch_dir()))
    os.close(fd)
    return path


def _write_wav(pcm16: bytes) -> str:
    """Write 16 kHz mono PCM16 bytes to a temp WAV and return its path."""
    path = _mktemp(".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm16)
    return path


def _unlink(path: Optional[str]) -> None:
    try:
        if path and os.path.exists(path):
            os.unlink(path)
    except OSError:
        pass


class WhisperTranscriber:
    """Default STT: the repo's own transcription path (local faster-whisper).

    The mic buffer is written to a 16 kHz mono WAV and handed to
    ``tools.transcription_tools.transcribe_audio`` — the same fixed decode path
    the rest of JarvisCopilot uses, honoring the user's ``stt`` config. A short
    buffer short-circuits to "" (nothing said), and an obvious whisper
    hallucination is filtered out when the helper is available.
    """

    def __init__(self, model: Optional[str] = None, realtime: bool = True):
        self.model = model
        self.realtime = realtime

    def __call__(self, pcm16: bytes) -> str:
        if len(pcm16) < MIN_PCM_BYTES:
            return ""
        path = _write_wav(pcm16)
        try:
            from tools.transcription_tools import transcribe_audio

            result = transcribe_audio(path, model=self.model, realtime=self.realtime)
        finally:
            _unlink(path)
        text = ""
        if isinstance(result, dict):
            text = (result.get("transcript") or "").strip()
        if text:
            try:
                from agent.voice_hallucination import is_hallucinated_output

                if is_hallucinated_output(text, mode="conversation"):
                    return ""
            except Exception:
                pass
        return text


class AuxiliaryBrain:
    """Default brain: one LLM turn via ``agent.auxiliary_client.call_llm``.

    Provider/model come from config (never hardcoded). When both are None the
    auxiliary client auto-resolves the user's configured provider.
    """

    def __init__(
        self,
        provider: Optional[str] = None,
        model: Optional[str] = None,
        system_prompt: str = "",
        max_tokens: int = 200,
        timeout: float = 60.0,
    ):
        self.provider = provider
        self.model = model
        self.system_prompt = system_prompt
        self.max_tokens = max_tokens
        self.timeout = timeout

    def __call__(self, transcript: str) -> str:
        from agent.auxiliary_client import call_llm, extract_content_or_reasoning

        resp = call_llm(
            provider=self.provider or None,
            model=self.model or None,
            messages=[
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": transcript},
            ],
            max_tokens=self.max_tokens,
            timeout=self.timeout,
        )
        try:
            return (extract_content_or_reasoning(resp) or "").strip()
        except Exception:
            try:
                return (resp.choices[0].message.content or "").strip()
            except Exception:
                return ""


class ConfigurableSynthesizer:
    """Default TTS: macOS ``say`` (reliable fallback) or the repo TTS tool.

    ``backend="jarvis"`` renders via ``tools.tts_tool.text_to_speech_tool`` and
    transcodes to 16 kHz mono PCM16 with ffmpeg, falling back to ``say`` on any
    failure (unconfigured provider, missing ffmpeg). ``backend="say"`` uses
    macOS ``say`` directly.
    """

    def __init__(self, backend: str = "say", say_voice: Optional[str] = None):
        self.backend = (backend or "say").lower()
        self.say_voice = say_voice

    def __call__(self, text: str) -> bytes:
        if self.backend == "jarvis":
            try:
                return self._jarvis_pcm16(text)
            except Exception:
                logger.warning("Jarvis TTS failed; falling back to macOS say", exc_info=True)
        return self._say_pcm16(text)

    def _say_pcm16(self, text: str) -> bytes:
        say_bin = shutil.which("say") or "/usr/bin/say"
        path = _mktemp(".wav")
        try:
            args = [say_bin, "-o", path, "--data-format=LEI16@16000"]
            if self.say_voice:
                args += ["-v", self.say_voice]
            args.append(text)
            subprocess.run(args, check=True)
            with wave.open(path, "rb") as w:
                if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (RATE, 1, 2):
                    raise RuntimeError(
                        "say produced {}Hz x{} {}-bit, expected 16kHz mono 16-bit".format(
                            w.getframerate(), w.getnchannels(), w.getsampwidth() * 8
                        )
                    )
                return w.readframes(w.getnframes())
        finally:
            _unlink(path)

    def _jarvis_pcm16(self, text: str) -> bytes:
        if not shutil.which("ffmpeg"):
            raise RuntimeError("ffmpeg not available for Jarvis-TTS transcode")
        from tools.tts_tool import text_to_speech_tool

        out = _mktemp(".mp3")
        src = None
        try:
            res = json.loads(text_to_speech_tool(text, output_path=out))
            src = res.get("file_path") or out
            if not res.get("success") or not src or not os.path.exists(src):
                raise RuntimeError("Jarvis TTS failed: " + str(res.get("error")))
            return subprocess.run(
                [
                    "ffmpeg", "-nostdin", "-loglevel", "error", "-i", src,
                    "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-",
                ],
                check=True,
                stdout=subprocess.PIPE,
            ).stdout
        finally:
            _unlink(out)
            if src and src != out:
                _unlink(src)


def warm_stt() -> None:
    """Best-effort: prebuild the local STT model so the first turn is fast."""
    try:
        from tools.transcription_tools import warm_stt as _warm

        _warm()
    except Exception:
        logger.debug("STT warm skipped", exc_info=True)


def default_transcriber(config) -> WhisperTranscriber:
    return WhisperTranscriber(model=config.stt_model, realtime=config.stt_realtime)


def default_brain(config) -> AuxiliaryBrain:
    return AuxiliaryBrain(
        provider=config.brain_provider,
        model=config.brain_model,
        system_prompt=config.brain_system_prompt,
        max_tokens=config.brain_max_tokens,
        timeout=config.brain_timeout,
    )


def default_synthesizer(config) -> ConfigurableSynthesizer:
    return ConfigurableSynthesizer(backend=config.tts_backend, say_voice=config.say_voice)
