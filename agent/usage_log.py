"""Usage for model calls that no session records.

``conversation_loop`` logs each call into state.db ``message_usage`` only when
the agent has a session DB. Review forks, one-shot agents (memory model,
harness routers) and auxiliary ``call_llm`` calls (titles, compression,
vision…) had none, so their spend was invisible to Insights → Costs. They are
recorded here under ``session_id = "usage:<source>"``; the Costs collector
prices every message_usage row, so they count in the existing totals and can
be split by source with a query. Best-effort: never raises.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

_DB = None
_DB_PATH: Optional[str] = None
_DB_LOCK = threading.Lock()


def _db():
    global _DB, _DB_PATH
    from jarviscopilot_constants import get_hermes_home
    path = str(get_hermes_home() / "state.db")
    with _DB_LOCK:
        if _DB is None or _DB_PATH != path:
            from jarviscopilot_state import SessionDB
            _DB = SessionDB(db_path=Path(path))
            _DB_PATH = path
        return _DB


def record(source: str, *, model: str, provider: str, usage: Any,
           latency_s: Optional[float] = None) -> None:
    """One message_usage row for a call no session recorded."""
    if usage is None:
        return
    try:
        _db().record_message_usage(
            session_id=f"usage:{source}",
            turn=0,
            timestamp=time.time(),
            model=model,
            provider=provider,
            input_tokens=int(getattr(usage, "input_tokens", 0) or 0),
            output_tokens=int(getattr(usage, "output_tokens", 0) or 0),
            cache_read_tokens=int(getattr(usage, "cache_read_tokens", 0) or 0),
            cache_write_tokens=int(getattr(usage, "cache_write_tokens", 0) or 0),
            reasoning_tokens=int(getattr(usage, "reasoning_tokens", 0) or 0),
            latency_s=latency_s,
            composition_json=json.dumps({"source": source}),
        )
    except Exception:
        logger.debug("usage not recorded for %s", source, exc_info=True)


def record_for_agent(agent, usage: Any, latency_s: Optional[float] = None) -> None:
    """Record an agent call made without a session DB, tagged with the agent's
    ``_usage_source`` (e.g. "review") or "agent:<platform>"."""
    source = getattr(agent, "_usage_source", None) or f"agent:{getattr(agent, 'platform', None) or 'unknown'}"
    record(source, model=str(getattr(agent, "model", "") or ""),
           provider=str(getattr(agent, "provider", "") or ""), usage=usage, latency_s=latency_s)


_HOST_PROVIDERS = (
    ("anthropic.com", "anthropic-api"),
    ("chatgpt.com", "openai-codex"),
    ("openrouter.ai", "openrouter"),
    ("ollama.com", "ollama-cloud"),
    ("celeris.ai", "celeris"),
    ("claude-cli://", "claude-code"),
    ("api.openai.com", "openai"),
    ("nvidia.com", "nvidia"),
)


def provider_for_client(client: Any) -> str:
    """The provider an auxiliary client bills, from its base URL (the Costs
    catalog maps these names to services); the host itself when unknown."""
    explicit = getattr(client, "provider", None)
    if isinstance(explicit, str) and explicit:
        return explicit
    base = str(getattr(client, "base_url", "") or "").lower()
    for needle, name in _HOST_PROVIDERS:
        if needle in base:
            return name
    return base.split("//", 1)[-1].split("/", 1)[0] or "auxiliary"


def usage_api_mode(usage: Any) -> str:
    """The usage shape: Anthropic (input/cache_creation fields) or chat completions."""
    if usage is not None and getattr(usage, "prompt_tokens", None) is None and (
            getattr(usage, "cache_creation_input_tokens", None) is not None
            or getattr(usage, "input_tokens", None) is not None):
        return "anthropic_messages"
    return "chat_completions"
