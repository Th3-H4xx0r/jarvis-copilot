"""The host carve-out: this machine's own agent calling its webui without a login.

The caller signs with the webui's key (``<webui state dir>/.signing_key``); the webui
(webui/api/auth.py) accepts the request from loopback when the signature is fresh.

Header ``X-JC-Host-Sig: <unix_ts>.<hex hmac-sha256>`` over ``METHOD\\nPATH\\nTIMESTAMP``.
The body is not part of the message.

Stdlib only: the webui, the agent's tools and standalone scripts all import it.
"""
import hashlib
import hmac
import os
import time
from pathlib import Path
from typing import Optional

HEADER = "X-JC-Host-Sig"
MAX_SKEW_SECONDS = 60


def webui_state_dir() -> Path:
    env = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / ".jarviscopilot" / "webui").resolve()


def read_key(state_dir: Optional[Path] = None) -> Optional[bytes]:
    try:
        return ((state_dir or webui_state_dir()) / ".signing_key").read_bytes()
    except OSError:
        return None


def _mac(key: bytes, method: str, path: str, ts: int) -> str:
    return hmac.new(key, f"{method.upper()}\n{path}\n{ts}".encode("utf-8"), hashlib.sha256).hexdigest()


def signature(key: bytes, method: str, path: str, now: Optional[int] = None) -> str:
    """The header value for one request."""
    ts = int(time.time()) if now is None else int(now)
    return f"{ts}.{_mac(key, method, path, ts)}"


def verify(key: bytes, method: str, path: str, value: str, now: Optional[int] = None) -> bool:
    """True for a well-formed, fresh signature by ``key`` over this method and path."""
    if not value or "." not in value:
        return False
    ts_str, sig = value.split(".", 1)
    try:
        ts = int(ts_str)
    except ValueError:
        return False
    if abs((int(time.time()) if now is None else int(now)) - ts) > MAX_SKEW_SECONDS:
        return False
    return hmac.compare_digest(sig.strip(), _mac(key, method, path, ts))
