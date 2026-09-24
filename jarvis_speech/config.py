"""`speech:` settings — one source for the server, the web and the phone.

`load()` is what the server reads (never raises: a hand-edited file must not stop
a voice turn), `validate()` is what a UI write must pass (raises, so the caller
can answer 400), and `merge()` folds a validated patch into the stored section
without wiping sibling keys.
"""
from __future__ import annotations

import copy
import os
from pathlib import Path
from typing import Any, Dict

DEFAULTS: Dict[str, Any] = {
    # Which engine turns speech into text for each surface. "local" / "edge"
    # are today's flow; anything else is a registered engine. An engine that
    # cannot run (no key) falls back to "local" (`engine_for` → None).
    "surfaces": {
        # Voice audio that reaches the server: a browser, and a phone or Mac set
        # to Soniox or unable to transcribe on the device.
        "voice": "soniox",
        # The Jarvis Pod's turns. Its own choice: its far-field mic is where the
        # local model is weakest.
        "pod": "soniox",
        "live": "edge",     # edge = the phone transcribes itself
        "upload": "local",  # /api/transcribe, Telegram/Discord voice notes
    },
    "soniox": {
        "model": "stt-rt-v5",
        "language_hints": [],
        "speaker_labels": True,
        "language_id": True,
        "custom_words": [],
        "endpoint_latency_level": 2,
        "endpoint_sensitivity": 0.3,
        "max_endpoint_delay_ms": 2000,
        # A Live stream is billed while open, so it closes after this much quiet.
        "live_quiet_close_s": 60,
    },
}
EDGE = "edge"

_RANGES = {
    "endpoint_latency_level": (0, 3),
    "endpoint_sensitivity": (-1.0, 1.0),
    "max_endpoint_delay_ms": (500, 3000),
    "live_quiet_close_s": (10, 3600),
}
_BOOLS = ("speaker_labels", "language_id")
_LISTS = ("language_hints", "custom_words")
_MAX_LIST = 200


def _raw_section() -> Dict[str, Any]:
    """The stored `speech:` section, copied — the shared config cache is never touched."""
    path = os.getenv("HERMES_CONFIG_PATH")
    if path:
        try:
            import yaml
            data = yaml.safe_load(Path(path).expanduser().read_text(encoding="utf-8-sig")) or {}
        except Exception:
            return {}
    else:
        try:
            from jarviscopilot_cli.config import load_config_readonly
            data = load_config_readonly()
        except Exception:
            return {}
    section = data.get("speech") if isinstance(data, dict) else None
    return copy.deepcopy(section) if isinstance(section, dict) else {}


def load() -> Dict[str, Any]:
    return coerce(_raw_section())


def coerce(raw: Dict[str, Any]) -> Dict[str, Any]:
    """Defaults with the stored values on top; a bad value falls back to its default."""
    out = copy.deepcopy(DEFAULTS)
    raw = raw if isinstance(raw, dict) else {}
    surfaces = raw.get("surfaces") if isinstance(raw.get("surfaces"), dict) else {}
    for name, default in DEFAULTS["surfaces"].items():
        value = surfaces.get(name)
        out["surfaces"][name] = value.strip() if isinstance(value, str) and value.strip() else default
    son = raw.get("soniox") if isinstance(raw.get("soniox"), dict) else {}
    for key, default in DEFAULTS["soniox"].items():
        if key not in son:
            continue
        value = son[key]
        if key in _BOOLS:
            out["soniox"][key] = _as_bool(value, default)
        elif key in _LISTS:
            out["soniox"][key] = _as_list(value)
        elif key in _RANGES:
            low, high = _RANGES[key]
            number = _as_num(value, type(default))
            out["soniox"][key] = number if number is not None and low <= number <= high else default
        elif isinstance(value, str) and value.strip():
            out["soniox"][key] = value.strip()
    return out


def validate(patch: Dict[str, Any]) -> Dict[str, Any]:
    """The clean subset of `patch`, or ValueError naming what is wrong."""
    from jarvis_speech import registry

    if not isinstance(patch, dict):
        raise ValueError("speech config must be an object")
    clean: Dict[str, Any] = {}
    surfaces = patch.get("surfaces")
    if isinstance(surfaces, dict):
        for name, value in surfaces.items():
            if name not in DEFAULTS["surfaces"]:
                continue
            value = str(value or "").strip()
            if name == "live":
                if value != EDGE and not _streams(registry, value):
                    raise ValueError(f"live needs 'edge' or an engine that streams, not {value!r}")
            elif value not in registry.names():
                raise ValueError(f"unknown speech engine {value!r}")
            clean.setdefault("surfaces", {})[name] = value
    son = patch.get("soniox")
    if isinstance(son, dict):
        if "api_key" in son:
            raise ValueError("the Soniox key is saved through /api/speech/soniox-key, not config")
        for key, value in son.items():
            if key not in DEFAULTS["soniox"]:
                continue
            if key in _BOOLS:
                value = _as_bool(value, None)
                if value is None:
                    raise ValueError(f"soniox.{key} must be true or false")
            elif key in _LISTS:
                value = _as_list(value)
            elif key in _RANGES:
                low, high = _RANGES[key]
                number = _as_num(value, type(DEFAULTS["soniox"][key]))
                if number is None or not low <= number <= high:
                    raise ValueError(f"soniox.{key} must be between {low} and {high}")
                value = number
            else:
                value = str(value or "").strip() or DEFAULTS["soniox"][key]
            clean.setdefault("soniox", {})[key] = value
    return clean


def merge(stored: Dict[str, Any], clean: Dict[str, Any]) -> Dict[str, Any]:
    """`clean` folded into `stored` one sub-section at a time, so siblings survive."""
    out = copy.deepcopy(stored) if isinstance(stored, dict) else {}
    for part in ("surfaces", "soniox"):
        if part in clean:
            base = out.get(part) if isinstance(out.get(part), dict) else {}
            base.update(clean[part])
            out[part] = base
    return out


def unknown_keys(patch: Dict[str, Any]) -> list:
    """Keys a caller sent that this version does not know, for its warning line."""
    if not isinstance(patch, dict):
        return []
    found = [key for key in patch if key not in DEFAULTS]
    for part in ("surfaces", "soniox"):
        if isinstance(patch.get(part), dict):
            found += [f"{part}.{key}" for key in patch[part]
                      if key not in DEFAULTS[part] and key != "api_key"]
    return sorted(found)


def _streams(registry, name: str) -> bool:
    engine = registry.get(name)
    return bool(engine is not None and getattr(engine, "streams", False))


def _as_bool(value, default):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in ("true", "yes", "on", "1"):
            return True
        if lowered in ("false", "no", "off", "0"):
            return False
    return default


def _as_list(value) -> list:
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, (list, tuple)):
        return []
    items = [str(item).strip() for item in value if str(item).strip()]
    return list(dict.fromkeys(items))[:_MAX_LIST]


def _as_num(value, kind):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if kind is float:
        return number
    return int(number) if number == int(number) else None
