"""Redact secret-bearing keys before logging an arg dict (passwords, tokens, …)."""
from __future__ import annotations

_SECRET_KEYS = {"password", "passwd", "secret", "token", "access_token",
                "api_key", "apikey", "authorization"}


def redact(obj):
    """A copy of obj with any secret-named value masked, recursively. Never raises."""
    try:
        if isinstance(obj, dict):
            return {k: ("***" if str(k).lower() in _SECRET_KEYS else redact(v)) for k, v in obj.items()}
        if isinstance(obj, (list, tuple)):
            return [redact(v) for v in obj]
    except Exception:  # noqa: BLE001
        return obj
    return obj
