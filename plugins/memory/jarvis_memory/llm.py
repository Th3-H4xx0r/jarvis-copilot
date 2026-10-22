"""The memory model: one setting for every model call memory makes.

Fact extraction, the map pass, the brief's inbox check and resolving a vague
"the venue" all go through ``complete``. The web server registers a completer
that follows his choice (a model, a harness, or Same as Default); outside it
(CLI, tests) the default is Haiku 5.5 on his Anthropic API key.
"""
from __future__ import annotations

import json
import threading
from typing import Callable, Optional

DEFAULT_AGENT = {"model": "claude-haiku-5-5", "provider": "anthropic-api"}
_SETTINGS_NS = "__settings__"
_KEY = "map_agent"

_lock = threading.Lock()
_completer: Optional[Callable[[str, int], str]] = None


def set_completer(fn: Optional[Callable[[str, int], str]]) -> None:
    global _completer
    with _lock:
        _completer = fn


def has_completer() -> bool:
    return _completer is not None


def complete(prompt: str, max_tokens: int = 1500) -> str:
    """One call to the memory model. Raises when it can't be reached."""
    fn = _completer
    if fn is not None:
        return str(fn(prompt, max_tokens) or "")
    from agent.auxiliary_client import call_llm, extract_content_or_reasoning
    resp = call_llm(task="memory_map", provider=DEFAULT_AGENT["provider"],
                    model=DEFAULT_AGENT["model"],
                    messages=[{"role": "user", "content": prompt}],
                    max_tokens=max_tokens, temperature=0.0, timeout=60)
    return str(extract_content_or_reasoning(resp) or "")


def clean_agent(agent):
    """(ok, agent) — None means Same as Default."""
    if agent is None:
        return True, None
    if not isinstance(agent, dict):
        return False, None
    if str(agent.get("harness_id") or "").strip():
        return True, {"harness_id": str(agent["harness_id"]).strip()}
    if str(agent.get("model") or "").strip():
        provider = str(agent.get("provider") or "").strip() or None
        return True, {"model": str(agent["model"]).strip(), "provider": provider}
    return False, None


def get_agent(store):
    raw = store.kv_get(_SETTINGS_NS, _KEY)
    if raw is None:
        return dict(DEFAULT_AGENT)
    try:
        value = json.loads(raw)
    except ValueError:
        return dict(DEFAULT_AGENT)
    return None if value == "default" else clean_agent(value)[1] or dict(DEFAULT_AGENT)


def set_agent(store, agent) -> bool:
    ok, cleaned = clean_agent(agent)
    if not ok:
        return False
    store.kv_set(_SETTINGS_NS, _KEY, json.dumps("default" if cleaned is None else cleaned))
    return True
