"""The Soniox key.

Read from the profile's `.env` FIRST, then the process environment: a key saved
from the settings UI lands in the file, and the gateway (a separate process that
copied `.env` into its environment at startup) must see the new one without a
restart. Nothing here logs or returns the key; `key_status` shows its last four.
"""
from __future__ import annotations

import os
from pathlib import Path

ENV_KEY = "SONIOX_API_KEY"


def env_path() -> Path:
    """The `.env` this key is read from — and the one a settings write must target."""
    try:
        from jarviscopilot_constants import get_hermes_home
        return Path(get_hermes_home()) / ".env"
    except Exception:
        home = os.getenv("HERMES_HOME")
        return Path(home) / ".env" if home else Path.home() / ".jarviscopilot" / ".env"


def _from_file(name: str):
    """The value in the profile's .env, "" when it has none — or None when there is no file."""
    try:
        lines = env_path().read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError):
        return ""
    for raw in lines:
        line = raw.strip()
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() == name:
            return value.strip().strip('"').strip("'").strip()
    return ""


def soniox_key() -> str:
    # When the profile has a .env, it decides: a key removed from it must stop
    # being used by the gateway too, which copied the old file into its
    # environment at startup. Without a file, the process environment is it.
    from_file = _from_file(ENV_KEY)
    if from_file is not None:
        return from_file
    return os.environ.get(ENV_KEY, "").strip()


def key_status() -> dict:
    key = soniox_key()
    if not key:
        return {"set": False, "hint": ""}
    return {"set": True, "hint": "••••" + (key[-4:] if len(key) >= 8 else "")}
