"""Settings → Web & browser over HTTP — shared by the web and the phone.

GET  /api/web/config   {config: {extract_model, engine, stealth_fallback,
                                 cloud_provider, cloud_for_interactive},
                        engines, lightpanda_installed, cloud_providers}
PUT  /api/web/config   a validated patch (POST too) → like GET plus ``ok``.

- ``extract_model`` (``web.extract_model``): the model browser_extract uses to turn a
  page into JSON — ``@provider:model``, ``harness:<id>``
  (the harness's Route picks per page) or "" for the default.
- ``engine`` (``browser.engine``): ``lightpanda`` (fast, Chrome when a site needs
  it) or ``chrome``.
- ``stealth_fallback`` (``web.stealth_fallback``): page reads (web_extract, web_search
  read_top) retry bot-blocked pages in a stealth browser.
- ``cloud_provider`` (``browser.cloud_provider``): the cloud browser browser tasks move
  to — ``none``, ``steel``, ``browserbase`` or ``browser-use`` (keys in Settings →
  Providers). ``none`` is stored as ``local``.
- ``cloud_for_interactive`` (``browser.cloud_for_interactive``, default on): the first
  click / type / key press of a task moves it to that cloud browser, so the chat shows
  it live. Off: only "Run on cloud browser" on the card moves a task. Saving either
  writes both, which also keeps tasks starting on the local engine (see
  tools.browser_tool._get_cloud_provider).
"""
from __future__ import annotations

import logging
import os
import re
import shutil
from typing import Any, Dict

from api import config as api_config
from api.helpers import bad, j

logger = logging.getLogger(__name__)

_PATH = "/api/web/config"
ENGINES = ("lightpanda", "chrome")
CLOUD_PROVIDERS = (
    ("none", "None", ()),
    ("steel", "Steel", ("STEEL_API_KEY",)),
    ("browserbase", "Browserbase", ("BROWSERBASE_API_KEY", "BROWSERBASE_PROJECT_ID")),
    ("browser-use", "Browser Use", ("BROWSER_USE_API_KEY",)),
)
_CLOUD_IDS = tuple(c[0] for c in CLOUD_PROVIDERS)
_REF = re.compile(r"^(?:@[A-Za-z0-9._-]+:[A-Za-z0-9._:/+-]+|harness:[A-Za-z0-9_-]{1,64})$")


def handle_web_config_get(handler, parsed) -> bool:
    if parsed.path != _PATH:
        return False
    j(handler, _payload(_stored()))
    return True


def handle_web_config_post(handler, parsed, body) -> bool:
    if parsed.path != _PATH:
        return False
    return _write(handler, body if isinstance(body, dict) else {})


def handle_web_config_put(handler, parsed, body) -> bool:
    return handle_web_config_post(handler, parsed, body)


def _lightpanda_installed() -> bool:
    try:
        from tools import lightpanda_local
        return lightpanda_local.available()
    except Exception:
        return shutil.which("lightpanda") is not None


def _stored() -> Dict[str, Any]:
    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    return stored if isinstance(stored, dict) else {}


def _has_env(name: str) -> bool:
    try:
        from api.profiles import get_active_hermes_home
        from api.providers import _load_env_file
        env_file = _load_env_file(get_active_hermes_home() / ".env")
    except Exception:
        env_file = {}
    return bool((env_file.get(name) or os.getenv(name) or "").strip())


def _cloud_provider(browser: Dict[str, Any]) -> str:
    raw = str(browser.get("cloud_provider") or "").strip().lower()
    if raw in ("", ):
        # Unset: a Steel key alone makes Steel the cloud browser.
        return "steel" if _has_env("STEEL_API_KEY") else "none"
    if raw in ("local", "none"):
        return "none"
    return raw


def _payload(stored: Dict[str, Any]) -> Dict[str, Any]:
    web = stored.get("web") if isinstance(stored.get("web"), dict) else {}
    browser = stored.get("browser") if isinstance(stored.get("browser"), dict) else {}
    engine = str(browser.get("engine") or "").lower()
    return {
        "config": {
            "extract_model": str(web.get("extract_model") or ""),
            "engine": "lightpanda" if engine == "lightpanda" else "chrome",
            "stealth_fallback": web.get("stealth_fallback", True) is not False,
            "cloud_provider": _cloud_provider(browser),
            "cloud_for_interactive": browser.get("cloud_for_interactive", True) is not False,
        },
        "engines": list(ENGINES),
        "lightpanda_installed": _lightpanda_installed(),
        "cloud_providers": [
            {"id": pid, "name": name, "has_key": all(_has_env(k) for k in keys) if keys else True}
            for pid, name, keys in CLOUD_PROVIDERS
        ],
    }


def _validate(body: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {"web": {}, "browser": {}}
    if "extract_model" in body:
        ref = body["extract_model"]
        if not isinstance(ref, str) or (ref.strip() and not _REF.match(ref.strip())):
            raise ValueError("extract_model must be empty, @provider:model or harness:<id>")
        out["web"]["extract_model"] = ref.strip()
    if "engine" in body:
        if body["engine"] not in ENGINES:
            raise ValueError("engine must be lightpanda or chrome")
        out["browser"]["engine"] = body["engine"]
    if "stealth_fallback" in body:
        if not isinstance(body["stealth_fallback"], bool):
            raise ValueError("stealth_fallback must be true or false")
        out["web"]["stealth_fallback"] = body["stealth_fallback"]
    if "cloud_provider" in body:
        if body["cloud_provider"] not in _CLOUD_IDS:
            raise ValueError("cloud_provider must be one of " + ", ".join(_CLOUD_IDS))
        out["browser"]["cloud_provider"] = "local" if body["cloud_provider"] == "none" else body["cloud_provider"]
    if "cloud_for_interactive" in body:
        if not isinstance(body["cloud_for_interactive"], bool):
            raise ValueError("cloud_for_interactive must be true or false")
        out["browser"]["cloud_for_interactive"] = body["cloud_for_interactive"]
    return out


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
                j(handler, {"error": "config.yaml could not be read, so nothing was saved; "
                                     "fix the file and try again"}, status=409)
                return True
            cloud_touched = bool({"cloud_provider", "cloud_for_interactive"} & set(clean["browser"]))
            if cloud_touched:
                # Both keys travel together: the live-browser setup is "tasks start
                # local; the cloud provider serves the sessions that move to it".
                current_browser = stored.get("browser") if isinstance(stored.get("browser"), dict) else {}
                clean["browser"].setdefault("cloud_for_interactive",
                                            current_browser.get("cloud_for_interactive", True) is not False)
                if "cloud_provider" not in clean["browser"] and not current_browser.get("cloud_provider"):
                    clean["browser"]["cloud_provider"] = _cloud_provider(current_browser).replace("none", "local")
            for section, values in clean.items():
                if values:
                    current = stored.get(section) if isinstance(stored.get(section), dict) else {}
                    current.update(values)
                    stored[section] = current
            api_config._save_yaml_config_file(path, stored)
        api_config.reload_config()
    except Exception:
        logger.warning("web config: writing the settings failed", exc_info=True)
        j(handler, {"error": "could not write the web settings"}, status=500)
        return True
    if clean["browser"]:
        # browser_tool caches the engine and the cloud provider per process:
        # re-read them on the next call.
        try:
            import tools.browser_tool as _bt
            _bt._browser_engine_resolved = False
            _bt._cloud_provider_resolved = False
            _bt._cached_cloud_provider = None
        except Exception:
            pass
    payload = _payload(stored)
    payload["ok"] = True
    j(handler, payload)
    return True
