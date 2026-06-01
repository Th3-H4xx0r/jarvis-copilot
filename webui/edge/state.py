"""Persistence for the edge subsystem.

Settings + the cloudflared tunnel token are stored under the active profile's
HERMES_HOME so they follow profile switches (matching how the rest of the WebUI
persists per-profile state). The token file is written ``0600`` and is never
echoed back to the UI in full — :func:`public_settings` masks it.
"""
from __future__ import annotations

import json
import os
import stat
import threading
from pathlib import Path
from typing import Any, Dict

_LOCK = threading.RLock()

# Defaults are intentionally conservative: nothing is exposed until the operator
# fills in a domain + token and explicitly enables the tunnel.
_DEFAULTS: Dict[str, Any] = {
    "enabled": False,            # is the tunnel intended to be running?
    "domain": "",               # apex domain, e.g. "example.com" → routes *.example.com
    "tunnel_name": "jarviscopilot",
    # hostname (subdomain or apex) → local target "127.0.0.1:PORT"
    "routes": {},               # e.g. {"jarvis": "127.0.0.1:8787"}
    "webui_port": 8787,
    "nginx_listen_port": 8788,   # nginx fronts the apps; cloudflared points here
    "trust_forwarded_host": True,  # nginx strips+resets these, so safe to honor
}

_TOKEN_FILENAME = "cloudflared_token"  # nosec - filename, not a secret
_SETTINGS_FILENAME = "edge.json"


def _home() -> Path:
    """Active profile home (HERMES_HOME), falling back to ~/.hermes."""
    h = os.getenv("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")
    return Path(h)


def _edge_dir() -> Path:
    d = _home() / "edge"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def _settings_path() -> Path:
    return _edge_dir() / _SETTINGS_FILENAME


def _token_path() -> Path:
    return _edge_dir() / _TOKEN_FILENAME


def load_settings() -> Dict[str, Any]:
    """Return the merged (defaults + persisted) settings dict."""
    with _LOCK:
        data = dict(_DEFAULTS)
        p = _settings_path()
        if p.exists():
            try:
                stored = json.loads(p.read_text(encoding="utf-8"))
                if isinstance(stored, dict):
                    data.update(stored)
            except (json.JSONDecodeError, OSError):
                pass
        # routes must always be a dict even if a corrupt file stored otherwise
        if not isinstance(data.get("routes"), dict):
            data["routes"] = {}
        return data


def save_settings(updates: Dict[str, Any]) -> Dict[str, Any]:
    """Merge *updates* into the persisted settings and return the new state.

    Unknown keys are ignored so the UI cannot inject arbitrary fields. The
    cloudflared token is NOT a settings field — use :func:`set_token`.
    """
    with _LOCK:
        data = load_settings()
        for k, v in (updates or {}).items():
            if k in _DEFAULTS:
                data[k] = v
        _settings_path().write_text(
            json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        try:
            os.chmod(_settings_path(), 0o600)
        except OSError:
            pass
        return data


def set_token(token: str) -> None:
    """Persist the cloudflared tunnel token at 0600 (empty string clears it)."""
    with _LOCK:
        p = _token_path()
        token = (token or "").strip()
        if not token:
            if p.exists():
                p.unlink()
            return
        # Write then chmod (umask-safe) so the secret is never briefly world-readable.
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, token.encode("utf-8"))
        finally:
            os.close(fd)
        os.chmod(p, stat.S_IRUSR | stat.S_IWUSR)


def get_token() -> str:
    """Return the stored token, or '' if none."""
    with _LOCK:
        p = _token_path()
        if not p.exists():
            return ""
        try:
            return p.read_text(encoding="utf-8").strip()
        except OSError:
            return ""


def has_token() -> bool:
    return bool(get_token())


def _mask(token: str) -> str:
    if not token:
        return ""
    if len(token) <= 8:
        return "••••"
    return f"{token[:4]}…{token[-4:]}"


def public_settings() -> Dict[str, Any]:
    """Settings safe to send to the UI: token is masked, never raw."""
    data = load_settings()
    tok = get_token()
    data = dict(data)
    data["has_token"] = bool(tok)
    data["token_masked"] = _mask(tok)
    return data
