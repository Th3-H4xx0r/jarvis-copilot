"""Live Jarvis settings — one source of truth for every client.

The mobile popup, the web modal and the server's own watchers all edit the same
`live:` section of the user's `config.yaml` through `GET/PUT /api/live/config`,
so a toggle flipped on the phone is the toggle the monitor reads. Device-local
choices (which mic, whether THIS device captures) deliberately stay on the
device and are not in here.

`embed_model` is load-bearing beyond being a setting: it is the id a device must
match to be granted the edge lane (design §5.3). Comparing vectors from two
different checkpoints is meaningless rather than merely imprecise, so a device
that declares a different id loses its lane instead of quietly corrupting
speaker identity.
"""
from __future__ import annotations

import logging
from typing import Any, Dict

logger = logging.getLogger(__name__)

CONFIG_SECTION = "live"

# Every key a client may read. Other layers (watchers, iOS, web) depend on these
# names, so a rename here is a protocol change.
DEFAULTS: Dict[str, Any] = {
    "enabled": True,
    "window_seconds": 60,
    "min_window_words": 25,
    "monitor": True,
    "fact_check": True,
    "translate": False,
    "memory_extraction": True,
    "artifacts": True,
    "reply_mode": "text",
    "primary_language": "en",
    # The model the watchers think with. Empty means "whatever a normal chat
    # turn uses", which is the setting that needs no setup and the one most
    # people should leave alone. `auxiliary.<task>.model` still wins over it,
    # so a per-task pin (a cheap monitor, a strong fact-check) is not undone by
    # picking one here.
    "model": "",
    # Names the checkpoint the server actually runs (see api/live_voiceprint.py):
    # WeSpeaker voxceleb_resnet34_LM. This used to say "ecapa-v1", which was a
    # lie in a load-bearing place — ECAPA-TDNN and ResNet34 are different
    # architectures producing incomparable vectors, and this id is the whole
    # interlock (§5.3): a device declaring it is promising its voiceprints can
    # be compared with the server's, and every `speaker_embedding` row is
    # stamped with it. `embeddings_for_model` filters on it, so any row written
    # under the old id simply stops matching — which is correct, not a
    # migration problem: no such rows exist in practice, and if they did they
    # would be ECAPA-shaped vectors this model cannot be compared against.
    "embed_model": "wespeaker-resnet34-lm-v1",
    # Roll a live session over once its transcript reaches this share of the
    # model's context window. Recording used to open a new session (and a new
    # chat) on every tap of Record.
    # How much recent conversation a fact-check sends. It checks the
    # recent stretch, not one line — checking "Yo, one, two, three" on its
    # own is meaningless.
    "fact_check_tokens": 1000,
    "session_rollover_fraction": 0.5,
    # A hard token ceiling that wins over the fraction when non-zero, for a
    # user who would rather name the number than trust a context lookup.
    "session_rollover_tokens": 0,
}

_BOOL_KEYS = ("enabled", "monitor", "fact_check", "translate",
              "memory_extraction", "artifacts")
_INT_KEYS = ("window_seconds", "min_window_words",
             "session_rollover_tokens",
             "fact_check_tokens")
_FLOAT_KEYS = ("session_rollover_fraction",)
_STR_KEYS = ("reply_mode", "primary_language", "embed_model", "model")
# Keys whose empty value MEANS something, so "" must round-trip instead of
# being rejected or replaced by the default. Clearing the model row is how the
# user says "follow the app", and there has to be a way back from a pick.
_OPTIONAL_STR_KEYS = ("model",)

REPLY_MODES = ("text", "spoken")

# A window shorter than this would put the monitor in a spin loop; longer than a
# day is a typo, not an intention. Bounds are rejected rather than clamped so the
# client sees that its value did not take.
_WINDOW_SECONDS_RANGE = (5, 24 * 60 * 60)


def load() -> Dict[str, Any]:
    """The effective settings: defaults with the user's `live:` section on top.

    Read from disk rather than `api.config.get_config()`'s mtime-keyed cache: a
    PUT followed immediately by a GET must show the value that was just written,
    and two writes inside one mtime tick are exactly the case the cache misses.
    """
    from api import config as api_config

    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    section = stored.get(CONFIG_SECTION) if isinstance(stored, dict) else None
    merged = _deep_merge(DEFAULTS, section if isinstance(section, dict) else {})
    return _coerce(merged)


def save(patch: Dict[str, Any]) -> Dict[str, Any]:
    """Merge `patch` into the `live:` section and return the new effective config.

    Unknown keys are dropped instead of persisted: this section is read by three
    clients and a typo'd key that survives a round-trip looks like a working
    setting forever. Invalid values raise `ValueError` so the caller can answer
    400 rather than silently storing something the watchers will ignore.
    """
    from api import config as api_config

    if not isinstance(patch, dict):
        raise ValueError("config patch must be an object")
    clean = _validate(patch)

    config_path = api_config._get_config_path()
    with api_config._cfg_lock:
        stored = api_config._load_yaml_config_file(config_path)
        section = stored.get(CONFIG_SECTION)
        if not isinstance(section, dict):
            section = {}
        section.update(clean)
        stored[CONFIG_SECTION] = section
        api_config._save_yaml_config_file(config_path, stored)
    # The rest of the process reads config through the cached loader; without
    # this it keeps serving the pre-write value until the mtime check notices.
    api_config.reload_config()
    return load()


def unknown_keys(patch: Dict[str, Any]) -> list:
    """Keys a caller sent that this version does not know, for its warning line."""
    if not isinstance(patch, dict):
        return []
    return sorted(k for k in patch if k not in DEFAULTS)


def _deep_merge(base: Dict[str, Any], over: Dict[str, Any]) -> Dict[str, Any]:
    """`DEFAULTS` is flat today; a future nested key must still inherit."""
    out = dict(base)
    for key, value in (over or {}).items():
        if key not in base:
            continue
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            out[key] = _deep_merge(base[key], value)
        else:
            out[key] = value
    return out


def _coerce(values: Dict[str, Any]) -> Dict[str, Any]:
    """Make a hand-edited config.yaml safe to read.

    Users edit this file directly, so `window_seconds: "60"` and
    `monitor: yes` both arrive here. A bad value falls back to its default
    instead of raising: a malformed settings file must not stop capture.
    """
    out = dict(values)
    for key in _BOOL_KEYS:
        out[key] = _as_bool(out.get(key), DEFAULTS[key])
    for key in _FLOAT_KEYS:
        out[key] = _as_float(out.get(key), DEFAULTS[key])
    for key in _INT_KEYS:
        out[key] = _as_int(out.get(key), DEFAULTS[key])
    for key in _STR_KEYS:
        raw = out.get(key)
        out[key] = str(raw).strip() if isinstance(raw, (str, int, float)) else ""
        if not out[key] and key not in _OPTIONAL_STR_KEYS:
            out[key] = DEFAULTS[key]
    if out["reply_mode"] not in REPLY_MODES:
        out["reply_mode"] = DEFAULTS["reply_mode"]
    low, high = _WINDOW_SECONDS_RANGE
    if not (low <= out["window_seconds"] <= high):
        out["window_seconds"] = DEFAULTS["window_seconds"]
    if out["min_window_words"] < 0:
        out["min_window_words"] = DEFAULTS["min_window_words"]
    fraction = out["session_rollover_fraction"]
    if not (0.05 <= fraction <= 1.0):
        out["session_rollover_fraction"] = DEFAULTS["session_rollover_fraction"]
    out["session_rollover_tokens"] = max(0, out["session_rollover_tokens"])
    if out["fact_check_tokens"] <= 0:
        out["fact_check_tokens"] = DEFAULTS["fact_check_tokens"]
    return out


def _validate(patch: Dict[str, Any]) -> Dict[str, Any]:
    clean: Dict[str, Any] = {}
    for key, raw in patch.items():
        if key not in DEFAULTS:
            continue
        if key in _BOOL_KEYS:
            if isinstance(raw, str):
                lowered = raw.strip().lower()
                if lowered not in ("true", "false", "1", "0", "yes", "no"):
                    raise ValueError(f"{key} must be a boolean")
                clean[key] = lowered in ("true", "1", "yes")
            elif isinstance(raw, bool):
                clean[key] = raw
            else:
                raise ValueError(f"{key} must be a boolean")
        elif key in _FLOAT_KEYS:
            try:
                value = float(raw)
            except (TypeError, ValueError):
                raise ValueError(f"{key} must be a number")
            # Outside this band is almost certainly a mistake: at 0 every
            # utterance would start a new session, which is the bug this
            # setting exists to fix, and above 1.0 means "past the context".
            if not (0.05 <= value <= 1.0):
                raise ValueError(
                    "session_rollover_fraction must be between 0.05 and 1.0")
            clean[key] = value
        elif key in _INT_KEYS:
            try:
                value = int(raw)
            except (TypeError, ValueError):
                raise ValueError(f"{key} must be an integer")
            if key == "window_seconds":
                low, high = _WINDOW_SECONDS_RANGE
                if not (low <= value <= high):
                    raise ValueError(
                        f"window_seconds must be between {low} and {high}")
            if key == "min_window_words" and value < 0:
                raise ValueError("min_window_words must be >= 0")
            if key == "session_rollover_tokens" and value < 0:
                raise ValueError("session_rollover_tokens must be >= 0")
            if key == "fact_check_tokens" and value <= 0:
                raise ValueError("fact_check_tokens must be > 0")
            clean[key] = value
        else:
            value = str(raw or "").strip()
            if not value and key not in _OPTIONAL_STR_KEYS:
                raise ValueError(f"{key} must not be empty")
            if key == "reply_mode" and value not in REPLY_MODES:
                raise ValueError(
                    f"reply_mode must be one of {', '.join(REPLY_MODES)}")
            clean[key] = value
    return clean


def _as_float(raw: Any, default: float) -> float:
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def _as_bool(raw: Any, default: bool) -> bool:
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, (int, float)):
        return bool(raw)
    if isinstance(raw, str):
        lowered = raw.strip().lower()
        if lowered in ("true", "1", "yes", "on"):
            return True
        if lowered in ("false", "0", "no", "off"):
            return False
    return default


def _as_int(raw: Any, default: int) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default
