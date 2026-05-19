"""Credential storage for the desktop client.

Two layers:

1. **OS keychain** via the ``keyring`` lib (macOS Keychain, Windows
   Credential Manager, Linux Secret Service). Stores the session cookie
   value, which is the only secret on disk.
2. **Plain config file** at ``<state_dir>/config.yaml`` (mode 0600).
   Holds the non-secret bits: server URL, pinned TLS cert fingerprint,
   device ID + name, allow-list flags. If keyring is unavailable
   (headless Linux box with no Secret Service running), the cookie
   falls back into this file too — still 0600, still single-user.

The public API is a small ``Credentials`` dataclass plus ``load()`` /
``save()`` helpers. Callers never touch keyring directly.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

from jc_client.logger import state_dir

log = logging.getLogger(__name__)

_CONFIG_FILE = state_dir() / "config.yaml"
_KEYRING_SERVICE = "jarviscopilot-client"
_KEYRING_USER = "session"


@dataclass
class Credentials:
    server_url: str = ""              # e.g. "https://1.2.3.4:8787"
    cert_fingerprint: str = ""        # SHA-256 hex, no colons
    device_id: str = ""
    device_name: str = ""
    cookie: str = ""                  # session cookie value (hermes_session=...)
    # Local skill allow-list. None = allow everything registered.
    skills_disabled: list[str] = field(default_factory=list)
    # Off by default — flipping to True opens the run_shell skill.
    allow_shell: bool = False

    @property
    def paired(self) -> bool:
        return bool(self.server_url and self.cookie and self.cert_fingerprint)


def _atomic_write(path: Path, text: str) -> None:
    """Write *text* to *path* with 0600 perms via tmp + os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=path.name + ".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass  # Windows; permission semantics differ
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _try_keyring_get() -> Optional[str]:
    try:
        import keyring  # type: ignore
        return keyring.get_password(_KEYRING_SERVICE, _KEYRING_USER)
    except Exception as exc:
        log.debug("keyring get failed: %s", exc)
        return None


def _try_keyring_set(value: str) -> bool:
    try:
        import keyring  # type: ignore
        keyring.set_password(_KEYRING_SERVICE, _KEYRING_USER, value)
        return True
    except Exception as exc:
        log.debug("keyring set failed: %s", exc)
        return False


def _try_keyring_delete() -> None:
    try:
        import keyring  # type: ignore
        keyring.delete_password(_KEYRING_SERVICE, _KEYRING_USER)
    except Exception:
        pass


def load() -> Credentials:
    """Read config from disk. Returns an empty Credentials if no file
    exists yet — caller checks ``.paired``."""
    if not _CONFIG_FILE.exists():
        return Credentials()
    try:
        raw = _CONFIG_FILE.read_text(encoding="utf-8")
        # We use JSON despite the .yaml name (simpler stdlib; valid YAML).
        # If a user hand-edited it as YAML, we fall through with a warning.
        try:
            data = json.loads(raw)
        except Exception:
            try:
                import yaml  # optional dep; only needed for hand-edited files
                data = yaml.safe_load(raw) or {}
            except Exception:
                log.warning("Could not parse %s — starting fresh", _CONFIG_FILE)
                return Credentials()
        if not isinstance(data, dict):
            return Credentials()
    except OSError as exc:
        log.warning("Could not read %s: %s", _CONFIG_FILE, exc)
        return Credentials()

    # Pull cookie from keyring first; the in-file copy is a fallback.
    cookie = _try_keyring_get() or data.get("cookie", "")
    return Credentials(
        server_url=data.get("server_url", ""),
        cert_fingerprint=data.get("cert_fingerprint", ""),
        device_id=data.get("device_id", ""),
        device_name=data.get("device_name", ""),
        cookie=cookie,
        skills_disabled=list(data.get("skills_disabled", []) or []),
        allow_shell=bool(data.get("allow_shell", False)),
    )


def save(creds: Credentials) -> None:
    """Persist non-secret fields to the config file and stash the cookie
    in keyring (with file fallback when keyring is unavailable)."""
    in_keyring = _try_keyring_set(creds.cookie) if creds.cookie else False
    payload = asdict(creds)
    if in_keyring:
        # Don't duplicate the secret to disk when keyring took it.
        payload.pop("cookie", None)
    _atomic_write(_CONFIG_FILE, json.dumps(payload, indent=2, sort_keys=True))


def clear() -> None:
    """Wipe credentials. Used by ``jc-client unpair``."""
    _try_keyring_delete()
    try:
        _CONFIG_FILE.unlink()
    except FileNotFoundError:
        pass


def update(**fields) -> Credentials:
    """Shortcut: load, mutate selected fields, save, return."""
    creds = load()
    for k, v in fields.items():
        if hasattr(creds, k):
            setattr(creds, k, v)
    save(creds)
    return creds
