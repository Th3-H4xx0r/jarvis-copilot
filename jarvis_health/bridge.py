"""Reaching a device skill from server-side code.

The device bridge's live sockets live in the webui process, so anything outside
it — a cron script, this SDK — asks over the loopback API with the host signing
key, exactly as the devices skill script does.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

_DEFAULT_TIMEOUT = 45
_signing_key: dict[str, Optional[bytes]] = {"key": None}


def state_dir() -> Path:
    env = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / ".jarviscopilot" / "webui").resolve()


def base_url() -> str:
    return os.environ.get("JC_WEBUI_URL") or "http://127.0.0.1:8765"


def _key() -> Optional[bytes]:
    if _signing_key["key"] is None:
        try:
            _signing_key["key"] = (state_dir() / ".signing_key").read_bytes()
        except OSError:
            return None
    return _signing_key["key"]


def _headers(method: str, path: str, body: bytes) -> dict[str, str]:
    """The host carve-out header, exactly as `webui/api/auth.py` verifies it.

    `X-JC-Host-Sig: <unix_ts>.<hex hmac>` over `METHOD\nPATH\nTIMESTAMP` with
    the webui's signing key, from loopback, within a ±60s skew. The body is not
    part of the message — signing it here would fail every request.
    """
    headers = {"Content-Type": "application/json"}
    key = _key()
    if not key:
        return headers
    stamp = int(time.time())
    message = f"{method}\n{path}\n{stamp}".encode("utf-8")
    signature = hmac.new(key, message, hashlib.sha256).hexdigest()
    headers["X-JC-Host-Sig"] = f"{stamp}.{signature}"
    return headers


def request(method: str, path: str, body: Optional[dict] = None, timeout: float = _DEFAULT_TIMEOUT) -> tuple[int, dict]:
    payload = json.dumps(body or {}).encode() if body is not None else b""
    req = urllib.request.Request(base_url() + path, data=payload or None, method=method)
    for name, value in _headers(method, path, payload).items():
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode() or "{}"
            return response.status, json.loads(raw)
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode() or "{}")
        except Exception:
            return exc.code, {"error": str(exc)}
    except Exception as exc:  # loopback down, socket refused, malformed JSON
        return 0, {"error": str(exc)}


def invoke(device_id: str, skill: str, args: Optional[dict] = None, timeout: float = 30) -> dict[str, Any]:
    """Run one device skill. The reply is the bridge's own {ok, result|error}."""
    status, data = request(
        "POST",
        "/api/devices/skills/invoke",
        {"device_id": device_id, "skill": skill, "args": args or {}, "timeout": timeout},
        timeout=timeout + 10,
    )
    if status == 0 or not isinstance(data, dict):
        return {"ok": False, "error": (data or {}).get("error") or "the webui did not answer"}
    return data
