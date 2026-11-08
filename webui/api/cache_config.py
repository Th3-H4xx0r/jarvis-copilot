"""'Keep prompts cached' over HTTP — shared by the web and the phone.

GET  /api/cache/config   {config: {retention}, defaults, options}
PUT  /api/cache/config   {retention: "standard" | "long"} (POST too)

The key is the agent's own ``prompt_caching.retention``: every agent on a model
starts with the same prompt (tools + stable system block), and providers keep
that start cached for a while. "standard" is the usual ~5 minutes; "long" asks
for an hour where the provider offers it (each adapter maps it — one that
caches on its own ignores it), so a chat paused for a few minutes doesn't
re-send its whole prompt. A save reaches the agents this server already holds
for the profile, in place.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict

from api import config as api_config
from api.helpers import bad, j

logger = logging.getLogger(__name__)

_PATH = "/api/cache/config"
_OPTIONS = ("standard", "long")
_DEFAULT = "long"


def handle_cache_get(handler, parsed) -> bool:
    if parsed.path != _PATH:
        return False
    j(handler, _payload(_stored_section()))
    return True


def handle_cache_post(handler, parsed, body) -> bool:
    if parsed.path != _PATH:
        return False
    return _write(handler, body if isinstance(body, dict) else {})


def handle_cache_put(handler, parsed, body) -> bool:
    return handle_cache_post(handler, parsed, body)


def _stored_section() -> Dict[str, Any]:
    # From disk: a PUT followed at once by a GET must show what was written.
    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    section = stored.get("prompt_caching") if isinstance(stored, dict) else None
    return section if isinstance(section, dict) else {}


def _effective(section: Dict[str, Any]) -> str:
    """The retention as agent_init reads it (the old cache_ttl only when unset)."""
    ret = section.get("retention")
    if ret in _OPTIONS:
        return ret
    return "long" if section.get("cache_ttl") == "1h" else _DEFAULT


def _payload(section: Dict[str, Any]) -> Dict[str, Any]:
    return {"config": {"retention": _effective(section)},
            "defaults": {"retention": _DEFAULT},
            "options": list(_OPTIONS)}


def _write(handler, body: Dict[str, Any]) -> bool:
    retention = body.get("retention")
    if retention not in _OPTIONS:
        bad(handler, "retention must be \"standard\" or \"long\"")
        return True
    section = {}

    def mutate(stored):
        section.update(stored.get("prompt_caching") if isinstance(stored.get("prompt_caching"), dict) else {})
        section["retention"] = retention
        stored["prompt_caching"] = section

    saved = api_config.edit_config_yaml(handler, mutate, what="cache settings",
                                        failure="could not write the prompt-cache setting")
    if saved is None:
        return True
    path = saved[1]
    _apply_to_live_agents(retention, path.parent)
    payload = _payload(section)
    payload["ok"] = True
    j(handler, payload)
    return True


def _apply_to_live_agents(retention: str, home: Path) -> int:
    """Switch the retention on every agent this server holds for this profile
    (the next request uses it; held agents also idle out on the new timer)."""
    updated = 0
    for agent in api_config.held_agents_for_home(home):
        agent._cache_retention = retention
        agent._cache_ttl = "1h" if retention == "long" else "5m"
        updated += 1
    return updated


def route(req) -> bool:
    """Mounted at /api/cache (api/mounts.py)."""
    if req.method == "GET":
        return handle_cache_get(req.handler, req.parsed)
    if req.method == "POST":
        return handle_cache_post(req.handler, req.parsed, req.body)
    if req.method == "PUT":
        return handle_cache_put(req.handler, req.parsed, req.body)
    return False
