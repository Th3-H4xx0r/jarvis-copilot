"""Memory map wiring for the web server.

- The memory model setting (one choice for every memory model call; default
  Haiku 5.5 on his Anthropic API key) and the completer that follows it.
- Registering the brief's live sources (calendar, health, inbox, home…).
- HTTP handlers for the setting, the phone's context snapshot and cleanup.
"""
from __future__ import annotations

import logging
from typing import Optional, Tuple

logger = logging.getLogger(__name__)

_MIGRATED_KEY = "imessage_agent_migrated"


def _store():
    from plugins.memory.jarvis_memory import external
    return external._open()[0]


def get_agent():
    """His choice: ``{"model", "provider"}``, ``{"harness_id"}`` or None (Same as Default)."""
    from plugins.memory.jarvis_memory import llm
    return llm.get_agent(_store())


def set_agent(agent) -> bool:
    from plugins.memory.jarvis_memory import llm
    return llm.set_agent(_store(), agent)


def resolve_map_model() -> Tuple[str, str]:
    from api.imessage_memory_writer import resolve_extraction_model
    return resolve_extraction_model(get_agent())


def complete(prompt: str, max_tokens: int = 1500) -> str:
    import api.imessage_memory_writer as writer
    ref, _label = resolve_map_model()
    if not ref:
        raise RuntimeError("no memory model set")
    return writer._one_shot(ref, prompt)


def migrate_imessage_choice() -> None:
    """Once: a model or harness he had picked for iMessage becomes the memory model."""
    store = _store()
    if store.kv_get("__settings__", _MIGRATED_KEY):
        return
    try:
        from api.imessage_memory import store as im_store
        agent = im_store().settings().get("agent")
    except Exception:
        agent = None
    if agent:
        set_agent(agent)
    store.kv_set("__settings__", _MIGRATED_KEY, "1")


def _register_brief_sources() -> None:
    try:
        from api import brief_sources
        brief_sources.register_all()
    except Exception:
        logger.warning("memory map: brief sources not registered", exc_info=True)


def install() -> None:
    """Called once at web server start."""
    from plugins.memory.jarvis_memory import llm
    llm.set_completer(complete)
    try:
        migrate_imessage_choice()
    except Exception:
        logger.warning("memory map: iMessage model choice not migrated", exc_info=True)
    _register_brief_sources()


# ── HTTP ─────────────────────────────────────────────────────────────────
def settings_payload() -> dict:
    agent = get_agent()
    try:
        _ref, label = resolve_map_model()
    except Exception:
        label = ""
    return {"agent": agent, "label": label}


def handle_settings_get(handler):
    from api.helpers import j
    return j(handler, settings_payload())


def handle_settings_post(handler, body: Optional[dict]):
    from api.helpers import bad, j
    body = body if isinstance(body, dict) else {}
    if "agent" not in body or not set_agent(body.get("agent")):
        return bad(handler, "agent must be null, {harness_id} or {model, provider}")
    return j(handler, settings_payload())
