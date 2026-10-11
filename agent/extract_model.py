"""The model that turns web pages into JSON (browser_extract).

Set in Settings → Web & browser as ``web.extract_model``:
- ``@provider:model`` — that model;
- ``harness:<id>`` — a harness whose Route picks the model for each page (e.g. small
  pages → a fast model, big ones → a stronger one). The web UI registers the
  resolver that runs the harness (core tools never import the web UI);
- empty — Claude Haiku 5.5 on the Anthropic API key when it is set, else the
  auxiliary default (``None``).
"""
from __future__ import annotations

import logging
from typing import Callable, Optional, Tuple

logger = logging.getLogger(__name__)

DEFAULT = ("anthropic-api", "claude-haiku-5-5")
_resolver: Optional[Callable[[str, str, int], Optional[str]]] = None


def register_resolver(fn: Optional[Callable[[str, str, int], Optional[str]]]) -> None:
    """``fn(harness_id, instruction, page_chars) -> "@provider:model" | None``."""
    global _resolver
    _resolver = fn


def configured() -> str:
    try:
        from jarviscopilot_cli.config import read_raw_config
        return str((read_raw_config().get("web") or {}).get("extract_model") or "").strip()
    except Exception:
        return ""


def _anthropic_api_ready() -> bool:
    try:
        from jarviscopilot_cli.auth import resolve_api_key_provider_credentials
        return bool(str((resolve_api_key_provider_credentials("anthropic-api") or {}).get("api_key") or "").strip())
    except Exception:
        return False


def _split(ref: str) -> Optional[Tuple[Optional[str], str]]:
    ref = (ref or "").strip()
    if not ref:
        return None
    if ref.startswith("@") and ":" in ref:
        provider, model = ref[1:].split(":", 1)
        return (provider or None), model
    return None, ref


def resolve(instruction: str, page_chars: int) -> Optional[Tuple[Optional[str], str]]:
    """``(provider, model)`` for this extraction, or None for the auxiliary default."""
    ref = configured()
    if ref.startswith("harness:"):
        picked = None
        if _resolver is not None:
            try:
                picked = _resolver(ref[len("harness:"):], instruction or "", int(page_chars or 0))
            except Exception:
                logger.warning("extraction harness %s failed; using the default model", ref, exc_info=True)
        ref = picked or ""
    got = _split(ref)
    if got:
        return got
    return DEFAULT if _anthropic_api_ready() else None
