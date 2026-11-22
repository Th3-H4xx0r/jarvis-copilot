"""Configuration for the standalone glasses relay server.

Resolution precedence (highest first):

    1. Explicit kwargs to ``RelayConfig(...)``.
    2. Environment overrides (``JARVIS_RELAY_*``).
    3. ``config.yaml`` — the ``auxiliary.voice`` lane for the brain
       provider/model, read through the repo's own config loader.
    4. Built-in defaults.

The brain provider/model deliberately default to ``None`` so that
``agent.auxiliary_client.call_llm`` auto-resolves the user's configured
provider. We never hardcode a specific provider (e.g. claude-code) here.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional, Tuple

# WebSocket defaults
DEFAULT_PORT = 8791
DEFAULT_PATH = "/v1/glasses/realtime"

# Audio framing (16 kHz mono PCM16)
RATE = 16_000
FRAME_SAMPLES = 640            # 40 ms at 16 kHz
FRAME_BYTES = FRAME_SAMPLES * 2
FRAME_SEC = FRAME_SAMPLES / RATE

DEFAULT_SYSTEM_PROMPT = (
    "You are Jarvis, a concise voice assistant speaking through a pair of "
    "glasses. The audio may begin with a wake phrase like 'Hey Meta' or "
    "'Hey Jarvis' - ignore it. Answer in one or two short spoken sentences. "
    "No lists, markdown, code fences or URLs."
)


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _voice_lane_provider_model() -> Tuple[Optional[str], Optional[str]]:
    """Read the brain provider/model from ``config.yaml`` (auxiliary.voice lane).

    Returns ``(None, None)`` when the config can't be read or the lane is
    unset/"auto" — the caller then lets ``call_llm`` auto-resolve the user's
    main provider. Import of the config loader is deferred so merely importing
    this module stays cheap and side-effect free.
    """
    try:
        from jarviscopilot_cli.config import load_config_readonly

        cfg = load_config_readonly()
    except Exception:
        return (None, None)
    if not isinstance(cfg, dict):
        return (None, None)
    aux = cfg.get("auxiliary") or {}
    lane = aux.get("voice") or {} if isinstance(aux, dict) else {}
    if not isinstance(lane, dict):
        return (None, None)
    provider = (lane.get("provider") or "").strip() or None
    model = (lane.get("model") or "").strip() or None
    if provider == "auto":
        provider = None
    if model == "auto":
        model = None
    return (provider, model)


@dataclass
class RelayConfig:
    """All knobs for a relay server instance. Construct directly in tests."""

    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    path: str = DEFAULT_PATH
    # Authorization: when set, require ``Authorization: Bearer <token>``.
    token: Optional[str] = None

    # STT
    stt_model: Optional[str] = None        # None = repo stt config default
    stt_realtime: bool = True              # use the fast realtime whisper model

    # Brain
    brain_provider: Optional[str] = None   # None = auxiliary_client auto-resolve
    brain_model: Optional[str] = None
    brain_system_prompt: str = DEFAULT_SYSTEM_PROMPT
    brain_max_tokens: int = 200
    brain_timeout: float = 60.0

    # TTS
    tts_backend: str = "say"               # "say" | "jarvis"
    say_voice: Optional[str] = None

    # Streaming
    realtime_pacing: bool = True           # pace PCM frames ~realtime to the relay
    max_audio_bytes: int = 8 * 1024 * 1024

    @classmethod
    def from_sources(cls, *, port: Optional[int] = None) -> "RelayConfig":
        """Build a config from env + config.yaml, with an optional port override."""
        cfg_provider, cfg_model = _voice_lane_provider_model()

        resolved_port = DEFAULT_PORT
        env_port = _env("JARVIS_RELAY_PORT")
        if env_port:
            resolved_port = int(env_port)
        if port is not None:
            resolved_port = port

        return cls(
            host=_env("JARVIS_RELAY_HOST") or "127.0.0.1",
            port=resolved_port,
            token=_env("JARVIS_RELAY_TOKEN") or None,
            stt_model=_env("JARVIS_RELAY_STT_MODEL") or None,
            brain_provider=_env("JARVIS_RELAY_PROVIDER") or cfg_provider or None,
            brain_model=_env("JARVIS_RELAY_MODEL") or cfg_model or None,
            brain_system_prompt=_env("JARVIS_RELAY_SYSTEM_PROMPT") or DEFAULT_SYSTEM_PROMPT,
            tts_backend=(_env("JARVIS_RELAY_TTS") or "say").lower(),
            say_voice=_env("JARVIS_RELAY_SAY_VOICE") or None,
        )
