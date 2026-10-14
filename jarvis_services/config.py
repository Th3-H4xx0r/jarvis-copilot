"""Where service settings live.

Secrets (API keys, tokens, exchange key/secret/passphrase, the Coinbase private key)
are in the active profile's ``.env``, written through the injected ``write_env``
(the web UI passes ``api.providers._write_env_file``). Everything else (n8n URL,
filters, crypto watchlist, wallet addresses) is in ``<home>/services.json``. One
home function serves both, so a profile switch never splits them.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import json
import os
import tempfile
import threading
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

SETTINGS_FILE = "services.json"
_LOCK = threading.Lock()


def _default_home() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home()


def _read_env_file(path: Path) -> dict:
    values: dict = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def _read_settings(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


class ConfigView:
    """One consistent read of secrets and settings, taken once per hub tick."""

    def __init__(self, env: Mapping[str, str], settings: Mapping[str, Any],
                 environ: Mapping[str, str] = os.environ):
        self._env = env
        self._settings = settings
        self._environ = environ

    def secret(self, name: str) -> str:
        return (self._env.get(name) or self._environ.get(name) or "").strip()

    def section(self, name: str) -> dict:
        value = self._settings.get(name)
        return dict(value) if isinstance(value, dict) else {}

    def setting(self, section: str, key: str, default: Any = None) -> Any:
        value = self.section(section).get(key)
        return default if value is None else value


class ServicesConfig:
    def __init__(self, home_fn: Optional[Callable[[], Path]] = None,
                 write_env: Optional[Callable[[Path, dict], None]] = None):
        self._home_fn = home_fn or _default_home
        self._write_env = write_env

    @property
    def home(self) -> Path:
        return Path(self._home_fn())

    def load(self) -> ConfigView:
        home = self.home
        return ConfigView(_read_env_file(home / ".env"), _read_settings(home / SETTINGS_FILE))

    def set_secrets(self, updates: Mapping[str, Optional[str]]) -> None:
        """``{ENV_NAME: value}`` saves, ``{ENV_NAME: None}`` removes."""
        if self._write_env is None:
            raise RuntimeError("no .env writer configured")
        self._write_env(self.home / ".env", dict(updates))

    def save_settings(self, section: str, values: Mapping[str, Any]) -> None:
        """Merge ``values`` into one section of services.json (atomic write)."""
        path = self.home / SETTINGS_FILE
        with _LOCK:
            stored = _read_settings(path)
            current = stored.get(section) if isinstance(stored.get(section), dict) else {}
            stored[section] = {**current, **values}
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".services_", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(stored, f, indent=2, sort_keys=True)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, path)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
