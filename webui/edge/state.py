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
    # Operator acknowledged the origin is protected even though it's not bound to
    # loopback (e.g. a container with no published ports, or a host firewall).
    # Satisfies the origin_bound_to_loopback preflight check.
    "loopback_ack": False,
    # Cloudflare Access service token. Native clients (mobile/desktop) send these
    # as CF-Access-Client-Id / CF-Access-Client-Secret to clear Access at the edge
    # non-interactively. Delivered to devices via the pairing payload. The secret
    # is stored in the 0600 token file (NOT here); only the id lives in settings.
    "cf_service_client_id": "",
}

# The CF service-token SECRET is a credential — store it alongside the tunnel
# token in a 0600 file, never in the plaintext settings json.
_CF_SECRET_FILENAME = "cf_service_token"  # nosec - filename, not a secret

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


def _cf_secret_path() -> Path:
    return _edge_dir() / _CF_SECRET_FILENAME


def _write_secret_file(path: Path, value: str) -> None:
    """Write *value* to *path* at 0600 (empty clears it). umask-safe."""
    value = (value or "").strip()
    if not value:
        if path.exists():
            path.unlink()
        return
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, value.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def _read_secret_file(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def set_cf_service_secret(secret: str) -> None:
    """Persist the Cloudflare Access service-token SECRET at 0600."""
    with _LOCK:
        _write_secret_file(_cf_secret_path(), secret)


def get_cf_service_secret() -> str:
    with _LOCK:
        return _read_secret_file(_cf_secret_path())


def get_cf_service_token() -> Dict[str, str]:
    """Return {client_id, client_secret} for the configured CF service token.

    Both empty when unconfigured — callers (pairing) then omit the fields so
    clients behave exactly as before a tunnel was set up.
    """
    with _LOCK:
        return {
            "client_id": (load_settings().get("cf_service_client_id") or "").strip(),
            "client_secret": get_cf_service_secret(),
        }


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
    """Settings safe to send to the UI: secrets masked, never raw."""
    data = load_settings()
    tok = get_token()
    data = dict(data)
    data["has_token"] = bool(tok)
    data["token_masked"] = _mask(tok)
    # Cloudflare Access service token: report presence + masked secret only.
    cf_secret = get_cf_service_secret()
    data["has_cf_service_token"] = bool(data.get("cf_service_client_id") and cf_secret)
    data["cf_service_secret_masked"] = _mask(cf_secret)
    return data
