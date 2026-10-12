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
            section = stored.get("prompt_caching") if isinstance(stored.get("prompt_caching"), dict) else {}
            section["retention"] = retention
            stored["prompt_caching"] = section
            api_config._save_yaml_config_file(path, stored)
        api_config.reload_config()
    except Exception:
        # Details to the log only: a write failure can carry a filesystem path.
        logger.warning("cache settings: writing failed", exc_info=True)
        j(handler, {"error": "could not write the prompt-cache setting"}, status=500)
        return True
    _apply_to_live_agents(retention, path.parent)
    payload = _payload(section)
    payload["ok"] = True
    j(handler, payload)
    return True


def _same_home(a: Any, b: Path) -> bool:
    try:
        return bool(a) and Path(str(a)).expanduser().resolve() == b.expanduser().resolve()
    except Exception:
        return False


def _apply_to_live_agents(retention: str, home: Path) -> int:
    """Switch the retention on every agent this server holds for this profile
    (the next request uses it; held agents also idle out on the new timer)."""
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
        agent._cache_retention = retention
        agent._cache_ttl = "1h" if retention == "long" else "5m"
        updated += 1
    return updated
