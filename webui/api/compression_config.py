"""Auto-compact (context compression) settings over HTTP — shared by the web and the phone.

GET  /api/compression/config[?model=&provider=]
     {config, defaults, limits, preview}. ``preview`` is the trigger for that
     model (the configured default model when none is given):
     {model, provider, context_length, threshold_tokens}.
PUT  /api/compression/config   a validated patch (POST too):
     {enabled?, threshold_percent? (10–95), max_context_tokens? (0 = none, else ≥16000),
      model?, provider?}; replies like GET, plus ``ignored_keys`` when any.

The keys are the agent's own ``compression.enabled`` / ``compression.threshold``
(stored as a ratio) / ``compression.max_context_tokens``, so the CLI, the
gateway and the WebUI all read the same thing. A save also reaches the agents
this server already holds for the profile, in place: only the trigger moves,
nothing in the prompt, so prompt caching is untouched.
"""
from __future__ import annotations

import logging
import math
from pathlib import Path
from typing import Any, Dict
from urllib.parse import parse_qs

from api import config as api_config
from api.helpers import bad, j

logger = logging.getLogger(__name__)

_PATH = "/api/compression/config"
_FIELDS = ("enabled", "threshold_percent", "max_context_tokens")
# The model fields only steer the preview; they are not settings.
_PREVIEW_FIELDS = ("model", "provider")
# A cap below this would compact on nearly every turn (system prompts alone
# run 10–40K tokens).
_MIN_CAP_TOKENS = 16_000
_MAX_CAP_TOKENS = 10_000_000


def handle_compression_get(handler, parsed) -> bool:
    if parsed.path != _PATH:
        return False
    query = parse_qs(parsed.query or "")
    model = (query.get("model") or [""])[0]
    provider = (query.get("provider") or [""])[0]
    j(handler, _payload(_stored_section(), model, provider))
    return True


def handle_compression_post(handler, parsed, body) -> bool:
    if parsed.path != _PATH:
        return False
    return _write(handler, body if isinstance(body, dict) else {})


def handle_compression_put(handler, parsed, body) -> bool:
    return handle_compression_post(handler, parsed, body)


# ── reading ────────────────────────────────────────────────────────────────

def _stored_section() -> Dict[str, Any]:
    # From disk rather than the mtime-keyed cache: a PUT followed at once by a
    # GET must show what was just written.
    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    section = stored.get("compression") if isinstance(stored, dict) else None
    return section if isinstance(section, dict) else {}


def _effective(section: Dict[str, Any]) -> Dict[str, Any]:
    """The stored section as the agent reads it (agent_init / ContextCompressor)."""
    from agent.context_compressor import normalize_threshold_percent

    enabled = str(section.get("enabled", True)).lower() in {"true", "1", "yes"}
    pct = normalize_threshold_percent(section.get("threshold", 0.50))
    try:
        cap = max(0, int(section.get("max_context_tokens") or 0))
    except (TypeError, ValueError):
        cap = 0
    return {"enabled": enabled, "threshold_percent": int(round(pct * 100)), "max_context_tokens": cap}


def _context_length_for(model: str, provider: str) -> int:
    """The window the WebUI already shows for a session model (0 = unknown)."""
    try:
        from api.routes import _resolve_context_length_for_session_model
        return int(_resolve_context_length_for_session_model(model, provider) or 0)
    except Exception:
        logger.debug("compression: context length lookup failed", exc_info=True)
        return 0


def _preview(effective: Dict[str, Any], model: str, provider: str) -> Dict[str, Any]:
    from agent.context_compressor import compute_threshold_tokens

    model = str(model or "").strip()
    provider = str(provider or "").strip()
    if not model:
        model_cfg = api_config.get_config().get("model", {})
        if isinstance(model_cfg, dict):
            model = str(model_cfg.get("default") or model_cfg.get("model") or "")
            provider = provider or str(model_cfg.get("provider") or "")
    if model:
        try:
            qualified = api_config.model_with_provider_context(model, provider or None)
            model, resolved_provider, _base_url = api_config.resolve_model_provider(qualified)
            provider = resolved_provider or provider
        except Exception:
            logger.debug("compression: could not resolve %r", model, exc_info=True)
    context_length = _context_length_for(model, provider) if model else 0
    return {
        "model": model,
        "provider": provider,
        "context_length": context_length,
        "threshold_tokens": compute_threshold_tokens(
            context_length, effective["threshold_percent"] / 100.0, effective["max_context_tokens"],
        ),
    }


def _payload(section: Dict[str, Any], model: str = "", provider: str = "") -> Dict[str, Any]:
    from agent.context_compressor import (
        DEFAULT_TRIGGER_PERCENT, MAX_TRIGGER_PERCENT, MIN_TRIGGER_PERCENT,
    )
    from agent.model_metadata import DEFAULT_FALLBACK_CONTEXT, MINIMUM_CONTEXT_LENGTH

    effective = _effective(section)
    return {
        "config": effective,
        "defaults": {"enabled": True, "threshold_percent": int(DEFAULT_TRIGGER_PERCENT * 100),
                     "max_context_tokens": 0},
        "limits": {"min_percent": int(round(MIN_TRIGGER_PERCENT * 100)),
                   "max_percent": int(round(MAX_TRIGGER_PERCENT * 100)),
                   "floor_tokens": MINIMUM_CONTEXT_LENGTH,
                   "min_cap_tokens": _MIN_CAP_TOKENS,
                   # The window assumed when a model's is unknown (context_length 0).
                   "fallback_context_length": DEFAULT_FALLBACK_CONTEXT},
        "preview": _preview(effective, model, provider),
    }


# ── writing ────────────────────────────────────────────────────────────────

def _validate(body: Dict[str, Any]) -> Dict[str, Any]:
    """The settings in ``body`` as config values; ValueError says what is wrong."""
    from agent.context_compressor import MAX_TRIGGER_PERCENT, MIN_TRIGGER_PERCENT

    clean: Dict[str, Any] = {}
    if "enabled" in body:
        if not isinstance(body["enabled"], bool):
            raise ValueError("enabled must be true or false")
        clean["enabled"] = body["enabled"]
    if "threshold_percent" in body:
        raw = body["threshold_percent"]
        lo, hi = int(round(MIN_TRIGGER_PERCENT * 100)), int(round(MAX_TRIGGER_PERCENT * 100))
        if isinstance(raw, bool) or not isinstance(raw, (int, float)) or not lo <= raw <= hi:
            raise ValueError(f"threshold_percent must be a number from {lo} to {hi}")
        clean["threshold"] = round(float(raw) / 100.0, 4)
    if "max_context_tokens" in body:
        raw = body["max_context_tokens"]
        if (isinstance(raw, bool) or not isinstance(raw, (int, float))
                or (isinstance(raw, float) and not (math.isfinite(raw) and raw.is_integer()))):
            raise ValueError("max_context_tokens must be a whole number of tokens")
        cap = int(raw)
        if cap != 0 and not _MIN_CAP_TOKENS <= cap <= _MAX_CAP_TOKENS:
            raise ValueError(f"max_context_tokens must be 0 (no cap) or {_MIN_CAP_TOKENS:,} "
                             f"to {_MAX_CAP_TOKENS:,}")
        clean["max_context_tokens"] = cap
    return clean


def _write(handler, body: Dict[str, Any]) -> bool:
    try:
        clean = _validate(body)
    except ValueError as exc:
        bad(handler, str(exc))
        return True
    path = api_config._get_config_path()
    try:
        with api_config._cfg_lock:
            stored = api_config._load_yaml_config_file(path)
            if not stored and path.exists() and path.stat().st_size > 0:
                # Unreadable (a YAML slip in a hand edit): saving would replace the
                # whole file with just this section.
                j(handler, {"error": "config.yaml could not be read, so nothing was saved; "
                                     "fix the file and try again"}, status=409)
                return True
            section = stored.get("compression") if isinstance(stored.get("compression"), dict) else {}
            section.update(clean)
            stored["compression"] = section
            api_config._save_yaml_config_file(path, stored)
        api_config.reload_config()
    except Exception:
        # Details to the log only: a write failure can carry a filesystem path.
        logger.warning("compression: writing the settings failed", exc_info=True)
        j(handler, {"error": "could not write the compression settings"}, status=500)
        return True
    _apply_to_live_agents(section, path.parent)
    payload = _payload(section, str(body.get("model") or ""), str(body.get("provider") or ""))
    payload["ok"] = True
    ignored = sorted(k for k in body if k not in _FIELDS and k not in _PREVIEW_FIELDS)
    if ignored:
        payload["ignored_keys"] = ignored
    j(handler, payload)
    return True


def _same_home(a: Any, b: Path) -> bool:
    try:
        return bool(a) and Path(str(a)).expanduser().resolve() == b.expanduser().resolve()
    except Exception:
        return False


def _apply_to_live_agents(section: Dict[str, Any], home: Path) -> int:
    """Move the trigger on every agent this server holds for this profile.

    Each harness node keeps its own agent (and model), so each recomputes
    against its own window. Returns how many agents were updated.
    """
    from agent.context_compressor import apply_compression_config

    try:
        with api_config.SESSION_AGENT_CACHE_LOCK:
            entries = list(api_config.SESSION_AGENT_CACHE.values())
    except Exception:
        return 0
    updated = 0
    for entry in entries:
        agent = entry[0] if isinstance(entry, tuple) and entry else None
        if agent is None or not _same_home(getattr(agent, "_webui_profile_home", ""), home):
            continue
        try:
            apply_compression_config(agent, section)
            updated += 1
        except Exception:
            logger.debug("compression: could not update a cached agent", exc_info=True)
    return updated
