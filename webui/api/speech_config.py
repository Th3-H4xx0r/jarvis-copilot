"""Speech engine settings over HTTP — the one place the phone, the web and the Mac change them.

GET  /api/speech/config      settings, engines, languages, key status, usage
PUT  /api/speech/config      a validated patch (POST too); unknown keys are listed back
POST /api/speech/soniox-key  {api_key}: saved into the profile .env ("" removes); never echoed
POST /api/speech/test        one tiny Soniox session with the saved key

Writes follow `live_config.save`: the whole config file under `_cfg_lock`, then
`reload_config()` so the cached loader sees it. The `speech:` section is merged
one sub-section at a time so a patch never wipes its siblings.
"""
from __future__ import annotations

import logging
from typing import Any, Dict

from api import config as api_config  # also puts the repo on sys.path for jarvis_speech
from api.helpers import bad, j

logger = logging.getLogger(__name__)

_MIN_KEY_LENGTH = 8


def handle_speech_get(handler, parsed) -> bool:
    if parsed.path == "/api/speech/config":
        return _read(handler)
    return False


def handle_speech_post(handler, parsed, body) -> bool:
    body = body if isinstance(body, dict) else {}
    if parsed.path == "/api/speech/config":
        return _write(handler, body)
    if parsed.path == "/api/speech/soniox-key":
        return _save_key(handler, body)
    if parsed.path == "/api/speech/test":
        return _test(handler)
    return False


def handle_speech_put(handler, parsed, body) -> bool:
    if parsed.path == "/api/speech/config":
        return _write(handler, body if isinstance(body, dict) else {})
    return False


def _stored_section() -> Dict[str, Any]:
    # From disk rather than the mtime-keyed cache: a PUT followed at once by a
    # GET must show what was just written.
    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    section = stored.get("speech") if isinstance(stored, dict) else None
    return section if isinstance(section, dict) else {}


def _read(handler) -> bool:
    from jarvis_speech import config as speech, keys, registry, usage
    from jarvis_speech.engines.soniox import LANGUAGES
    try:
        payload = {"config": speech.coerce(_stored_section()), "defaults": speech.DEFAULTS,
                   "engines": registry.engines(), "languages": LANGUAGES,
                   "soniox_key": keys.key_status(), "usage": usage.summary()}
    except Exception:
        logger.warning("speech: could not read the settings", exc_info=True)
        j(handler, {"error": "could not read the speech settings"}, status=500)
        return True
    j(handler, payload)
    return True


def _write(handler, body: Dict[str, Any]) -> bool:
    from jarvis_speech import config as speech
    patch = body.get("config") if isinstance(body.get("config"), dict) else body
    try:
        clean = speech.validate(patch)
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
            current = stored.get("speech") if isinstance(stored.get("speech"), dict) else {}
            stored["speech"] = speech.merge(current, clean)
            api_config._save_yaml_config_file(path, stored)
        api_config.reload_config()
    except Exception:
        # Details to the log only: a write failure can carry a filesystem path.
        logger.warning("speech: writing the settings failed", exc_info=True)
        j(handler, {"error": "could not write the speech settings"}, status=500)
        return True
    payload = {"ok": True, "config": speech.coerce(stored["speech"])}
    ignored = speech.unknown_keys(patch)
    if ignored:
        payload["ignored_keys"] = ignored
    j(handler, payload)
    return True


def _save_key(handler, body: Dict[str, Any]) -> bool:
    from jarvis_speech import keys
    value = str(body.get("api_key") or "").strip()
    if "\n" in value or "\r" in value:
        bad(handler, "the key must be a single line")
        return True
    if value and len(value) < _MIN_KEY_LENGTH:
        bad(handler, "that does not look like a Soniox key")
        return True
    try:
        from api.providers import _write_env_file
        _write_env_file(keys.env_path(), {keys.ENV_KEY: value or None})
    except Exception as exc:
        # Never log the exception text: nothing guarantees it leaves the value out.
        logger.warning("speech: could not save the Soniox key (%s)", type(exc).__name__)
        j(handler, {"error": "could not save the key"}, status=500)
        return True
    j(handler, {"ok": True, "soniox_key": keys.key_status()})
    return True


def _test(handler) -> bool:
    from jarvis_speech import registry
    engine = registry.get("soniox")
    try:
        ok, message = engine.check() if engine is not None else (False, "the Soniox engine is missing")
    except Exception as exc:
        ok, message = False, f"check failed ({type(exc).__name__})"
    j(handler, {"ok": bool(ok), "message": str(message)})
    return True
