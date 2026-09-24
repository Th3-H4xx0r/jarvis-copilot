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


def _env_file() -> Path:
    try:
        from jarviscopilot_constants import get_hermes_home
        return Path(get_hermes_home()) / ".env"
    except Exception:
        home = os.getenv("HERMES_HOME")
        return Path(home) / ".env" if home else Path.home() / ".jarviscopilot" / ".env"


def _from_file(name: str) -> str:
    try:
        lines = _env_file().read_text(encoding="utf-8").splitlines()
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
    return _from_file(ENV_KEY) or os.environ.get(ENV_KEY, "").strip()


def key_status() -> dict:
    key = soniox_key()
    if not key:
        return {"set": False, "hint": ""}
    return {"set": True, "hint": "••••" + (key[-4:] if len(key) >= 8 else "")}
