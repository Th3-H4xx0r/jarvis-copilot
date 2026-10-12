"""Settings → Providers → tool keys: API keys for tools (not models), set from the web UI.

GET  /api/tool-keys  {tools: [{id, display_name, purpose, hint, url, has_key, in_use}]}
POST /api/tool-keys  {tool, api_key}: a key saves it to the active profile's .env,
                     an empty / null key removes it → like GET plus ``ok`` and ``action``.

Saving the Parallel key also makes Parallel the web search backend
(``web.search_backend``); removing it hands search back to the free engine.
Page reads stay on the free local reader, so Parallel credits only pay for searches.
The key itself is never returned.
"""
from __future__ import annotations

import logging
import os
import re
from typing import Any, Dict, List, Optional

from api import config as api_config
from api.helpers import bad, j

logger = logging.getLogger(__name__)

_PATH = "/api/tool-keys"
_KEY_RE = re.compile(r"^\S{8,512}$")

TOOL_KEYS: Dict[str, Dict[str, str]] = {
    "parallel": {
        "display_name": "Parallel",
        "env": "PARALLEL_API_KEY",
        "purpose": "Web search",
        "hint": "Jarvis's web search: fast mode, about $1 per 1,000 searches. "
                "If Parallel fails or runs out of credits, search falls back to free DuckDuckGo.",
        "url": "https://platform.parallel.ai",
        "search_backend": "parallel",
    },
}


def handle_tool_keys_get(handler, parsed) -> bool:
    if parsed.path != _PATH:
        return False
    j(handler, {"tools": _tools()})
    return True


def handle_tool_keys_post(handler, parsed, body) -> bool:
    if parsed.path != _PATH:
        return False
    body = body if isinstance(body, dict) else {}
    tool_id = str(body.get("tool") or "").strip().lower()
    spec = TOOL_KEYS.get(tool_id)
    if spec is None:
        bad(handler, "unknown tool")
        return True
    raw = body.get("api_key")
    if raw is not None and not isinstance(raw, str):
        bad(handler, "api_key must be text")
        return True
    key: Optional[str] = (raw or "").strip() or None
    if key is not None and not _KEY_RE.match(key):
        bad(handler, "That doesn't look like an API key (8+ characters, no spaces).")
        return True

    from api.providers import _get_hermes_home, _write_env_file
    try:
        _write_env_file(_get_hermes_home() / ".env", {spec["env"]: key})
    except Exception:
        logger.warning("tool keys: writing %s failed", spec["env"], exc_info=True)
        j(handler, {"error": "could not save the key"}, status=500)
        return True
    try:
        _set_search_backend(spec.get("search_backend"), key is not None)
    except Exception:
        logger.warning("tool keys: switching web.search_backend failed", exc_info=True)
        j(handler, {"error": "the key was saved, but web search could not be switched over"}, status=500)
        return True
    j(handler, {"ok": True, "tool": tool_id, "action": "saved" if key else "removed", "tools": _tools()})
    return True


def _set_search_backend(backend: Optional[str], key_saved: bool) -> None:
    """Saving a search tool's key makes it the search backend; removing it clears the
    setting only when that tool was the one chosen."""
    if not backend:
        return
    path = api_config._get_config_path()
    with api_config._cfg_lock:
        stored = api_config._load_yaml_config_file(path)
        if not stored and path.exists() and path.stat().st_size > 0:
            raise RuntimeError("config.yaml could not be read")
        web = stored.get("web") if isinstance(stored.get("web"), dict) else {}
        current = str(web.get("search_backend") or "").strip().lower()
        if key_saved:
            web["search_backend"] = backend
            # With no page reader chosen, the extract lookup walks a paid-first list
            # and the new key would take over page reads too: keep them local.
            if not str(web.get("extract_backend") or "").strip():
                web["extract_backend"] = "local"
        elif current == backend:
            web["search_backend"] = ""
        else:
            return
        stored["web"] = web
        api_config._save_yaml_config_file(path, stored)
    api_config.reload_config()


def _tools() -> List[Dict[str, Any]]:
    from api.providers import _get_hermes_home, _load_env_file
    env_file = _load_env_file(_get_hermes_home() / ".env")
    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    web = stored.get("web") if isinstance(stored, dict) and isinstance(stored.get("web"), dict) else {}
    search_backend = str(web.get("search_backend") or "").strip().lower()
    out = []
    for tool_id, spec in TOOL_KEYS.items():
        has_key = bool((env_file.get(spec["env"]) or os.getenv(spec["env"]) or "").strip())
        out.append({
            "id": tool_id,
            "display_name": spec["display_name"],
            "purpose": spec["purpose"],
            "hint": spec["hint"],
            "url": spec["url"],
            "has_key": has_key,
            "in_use": has_key and bool(spec.get("search_backend")) and search_backend == spec["search_backend"],
        })
    return out
