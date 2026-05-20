"""FCM HTTP v1 sender.

No external SDK — we read the Google service-account JSON, sign a JWT
asserting ``https://www.googleapis.com/auth/firebase.messaging``, exchange
it for an OAuth bearer token, then POST to
``https://fcm.googleapis.com/v1/projects/<project_id>/messages:send``.

The bearer token is cached in memory until it nears expiry (it's good for
1 hour by default; we refresh at 50 minutes to avoid races).

Service-account file shape (Google-generated, leave fields as-is)::

    {
      "type": "service_account",
      "project_id": "your-project",
      "private_key": "-----BEGIN PRIVATE KEY-----\\n...",
      "client_email": "fcm-sender@your-project.iam.gserviceaccount.com",
      ...
    }
"""
from __future__ import annotations

import base64
import json
import logging
import threading
import time
import urllib.request
import urllib.parse
import urllib.error
from typing import Optional

from api.config import STATE_DIR

logger = logging.getLogger(__name__)

_SA_FILE = STATE_DIR / ".fcm-service-account.json"

_TOKEN_LOCK = threading.Lock()
_token_cache: dict = {"access_token": "", "expires_at": 0.0, "project_id": ""}

_TOKEN_TTL_SAFETY_MARGIN = 600  # refresh 10 min before expiry


def fcm_configured() -> bool:
    return _SA_FILE.exists()


def _load_service_account() -> Optional[dict]:
    if not _SA_FILE.exists():
        return None
    try:
        return json.loads(_SA_FILE.read_text(encoding="utf-8"))
    except Exception as exc:
        logger.warning("invalid FCM service account file: %s", exc)
        return None


def _b64url(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def _sign_jwt(sa: dict) -> str:
    """Sign a JWT for OAuth2 token exchange.

    Requires the ``cryptography`` package for RS256 signing. It's a
    transitive dependency of many Python web stacks but we tolerate its
    absence by surfacing a clear error to the caller.
    """
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
    except ImportError as exc:
        raise RuntimeError(
            "FCM JWT signing requires the 'cryptography' package — "
            "install it with `pip install cryptography`"
        ) from exc

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": sa["client_email"],
        "scope": "https://www.googleapis.com/auth/firebase.messaging",
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode()) + b"." +
        _b64url(json.dumps(claims, separators=(",", ":")).encode())
    )
    key = serialization.load_pem_private_key(
        sa["private_key"].encode("utf-8"), password=None
    )
    sig = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return (signing_input + b"." + _b64url(sig)).decode("ascii")


def _exchange_for_access_token(sa: dict, timeout: float) -> tuple[str, float]:
    """Trade the signed JWT for an OAuth bearer. Returns (token, expires_at)."""
    jwt = _sign_jwt(sa)
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt,
    }).encode("ascii")
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8", "replace"))
    token = payload.get("access_token") or ""
    expires_in = int(payload.get("expires_in") or 0)
    if not token:
        raise RuntimeError(f"OAuth response missing access_token: {payload!r}")
    return token, time.time() + max(60, expires_in - _TOKEN_TTL_SAFETY_MARGIN)


def _get_access_token(timeout: float) -> tuple[str, str]:
    """Returns (access_token, project_id). Caches across calls."""
    with _TOKEN_LOCK:
        now = time.time()
        if _token_cache["access_token"] and _token_cache["expires_at"] > now:
            return _token_cache["access_token"], _token_cache["project_id"]
        sa = _load_service_account()
        if not sa:
            raise RuntimeError("FCM service account not configured")
        token, exp = _exchange_for_access_token(sa, timeout=timeout)
        _token_cache["access_token"] = token
        _token_cache["expires_at"] = exp
        _token_cache["project_id"] = sa.get("project_id") or ""
        return token, _token_cache["project_id"]


def send_fcm(push_token: str, payload: dict, *, timeout: float = 10.0) -> dict:
    """POST a data message via FCM HTTP v1.

    ``payload`` must be a flat dict of strings (FCM ``data`` payloads are
    string-typed). We stringify each value defensively so callers don't
    have to.
    """
    if not fcm_configured():
        return {"ok": False, "error": "FCM not configured"}
    try:
        token, project_id = _get_access_token(timeout=timeout)
    except Exception as exc:
        logger.warning("FCM token exchange failed: %s", exc)
        return {"ok": False, "error": f"FCM token: {exc}"}
    if not project_id:
        return {"ok": False, "error": "FCM project_id missing"}
    data = {k: str(v) for k, v in (payload or {}).items()}
    body = {
        "message": {
            "token": push_token,
            "data": data,
            # High priority on the data channel so the message is delivered
            # promptly even when the device is in Doze / app-standby buckets.
            "android": {"priority": "HIGH"},
        }
    }
    req = urllib.request.Request(
        f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_body = resp.read().decode("utf-8", "replace")
        return {"ok": True, "response": resp_body}
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:500]
        except Exception:
            pass
        # 404 / UNREGISTERED → token is stale; surface that to the caller
        # so it can prune the device record.
        return {
            "ok": False,
            "error": f"FCM HTTP {exc.code}: {detail or exc.reason}",
            "status": exc.code,
        }
    except Exception as exc:
        return {"ok": False, "error": f"FCM send: {exc}"}
