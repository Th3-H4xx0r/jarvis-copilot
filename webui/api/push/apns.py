"""APNs HTTP/2 sender (token-based JWT auth).

Auth key file (Apple-issued ``.p8``) goes at ``STATE_DIR/.apns-auth-key.p8``.
Companion config at ``STATE_DIR/.apns-config.json``::

    {
      "key_id":   "ABCDE12345",       // 10-char Apple Key ID
      "team_id":  "ABCDE12345",       // 10-char Apple Team ID
      "topic":    "com.your.bundle",  // app's bundle ID
      "use_sandbox": false             // true while testing on TestFlight Debug builds
    }

APNs requires HTTP/2. Python stdlib doesn't ship an HTTP/2 client, so we
prefer ``httpx[http2]`` when available; if absent the module reports
``apns_configured() == False`` and ``send_apns()`` returns a clear error
instead of blowing up. The mobile design tolerates missing iOS push (the
in-foreground WS path still works).
"""
from __future__ import annotations

import base64
import json
import logging
import threading
import time
from pathlib import Path
from typing import Optional

from api.config import STATE_DIR

logger = logging.getLogger(__name__)

_KEY_FILE = STATE_DIR / ".apns-auth-key.p8"
_CONFIG_FILE = STATE_DIR / ".apns-config.json"

_JWT_TTL = 50 * 60  # APNs JWTs are valid up to 1 hour; refresh at 50 min.
_JWT_LOCK = threading.Lock()
# Keyed by key_id: with more than one auth key a single cached token would be handed
# to the wrong key's pushes and APNs would reject them as InvalidProviderToken.
_jwt_cache: dict = {}

# A POOLED, long-lived HTTP/2 client. APNs is designed for a persistent HTTP/2
# connection: opening a fresh ``httpx.Client`` per push (the old behavior) did a
# full TCP+TLS handshake every time — slow, and the source of the intermittent
# "handshake operation timed out" failures that made the Live Activity lag / go
# stale. We reuse one connection across pushes (httpx.Client is thread-safe and
# multiplexes concurrent requests over HTTP/2) and self-heal on a dead socket.
_CLIENT_LOCK = threading.Lock()
_client_cache: dict = {"client": None}


def _get_apns_client():
    import httpx
    with _CLIENT_LOCK:
        c = _client_cache["client"]
        if c is None or getattr(c, "is_closed", False):
            c = httpx.Client(
                http2=True,
                # Short keepalive so the pool proactively retires an idle conn
                # BEFORE Apple silently drops it (which would cost a full timeout
                # to discover on the next use).
                limits=httpx.Limits(max_keepalive_connections=4,
                                    keepalive_expiry=90.0),
            )
            _client_cache["client"] = c
        return c


def _apns_post(url: str, headers: dict, body_str: str, timeout: float):
    """POST to APNs over the pooled HTTP/2 client; retry ONCE on a transport error.

    We do NOT close/reset the shared client on error — httpx's pool evicts a
    dead/half-open connection itself and opens a fresh one on the next request, so
    the retry self-heals WITHOUT closing a client other threads may be mid-`post`
    on (which would surface as an uncaught ``RuntimeError`` and spuriously fail a
    healthy concurrent push). A duplicate push from the retry is harmless: a Live
    Activity update is last-write-wins, and a device alert dup is benign."""
    import httpx
    last = None
    for _ in (1, 2):
        try:
            return _get_apns_client().post(
                url, headers=headers, content=body_str, timeout=timeout)
        except httpx.HTTPError as exc:  # transport/timeout/protocol error
            last = exc  # the pool replaces the dead connection on the next try
    raise last


def _load_config() -> Optional[dict]:
    if not _CONFIG_FILE.exists():
        return None
    try:
        data = json.loads(_CONFIG_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return None
        required = ("key_id", "team_id", "topic")
        if not all(data.get(k) for k in required):
            return None
        return data
    except Exception as exc:
        logger.warning("invalid APNs config: %s", exc)
        return None


def _config_for(topic: Optional[str]) -> Optional[dict]:
    """Pick the credentials for a given bundle ID.

    Apple caps APNs auth keys per team, and a key can be restricted to one
    environment — so a development-signed second app may need its own key rather
    than sharing the first. ``additional`` entries in the config are matched by
    ``topic``; anything unmatched falls back to the root config, which keeps
    existing single-key setups working untouched.
    """
    root = _load_config()
    if not root:
        return None
    if topic:
        for entry in (root.get("additional") or []):
            if not isinstance(entry, dict) or entry.get("topic") != topic:
                continue
            merged = {**root, **entry}
            merged.pop("additional", None)
            key_file = entry.get("key_file")
            merged["_key_path"] = str(STATE_DIR / key_file) if key_file else str(_KEY_FILE)
            if not Path(merged["_key_path"]).exists():
                logger.warning("APNs key file missing for topic %s: %s",
                               topic, merged["_key_path"])
                return None
            return merged
    return {**root, "_key_path": str(_KEY_FILE)}


def _have_httpx() -> bool:
    """True only if httpx AND HTTP/2 support are available. APNs is HTTP/2-only,
    so httpx installed without the ``[http2]`` extra (the ``h2`` package) can't
    reach Apple — checking ``import httpx`` alone gives a false positive that
    silently breaks every push at send time."""
    try:
        import httpx  # noqa: F401
        import h2  # noqa: F401  # httpx needs this for http2=True
        return True
    except ImportError:
        return False


def apns_configured() -> bool:
    return _KEY_FILE.exists() and _load_config() is not None and _have_httpx()


def _b64url(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def _sign_jwt(cfg: dict) -> str:
    """ES256-sign a JWT against the .p8 private key."""
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec, utils
    except ImportError as exc:
        raise RuntimeError(
            "APNs signing requires the 'cryptography' package — "
            "install it with `pip install cryptography`"
        ) from exc

    pem = Path(cfg.get("_key_path") or _KEY_FILE).read_bytes()
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise RuntimeError("APNs auth key must be an EC private key (ES256)")

    now = int(time.time())
    header = {"alg": "ES256", "kid": cfg["key_id"]}
    claims = {"iss": cfg["team_id"], "iat": now}
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode()) + b"." +
        _b64url(json.dumps(claims, separators=(",", ":")).encode())
    )
    # ECDSA signatures from `cryptography` are DER-encoded; APNs needs raw
    # R||S, 32 bytes each, so we decode and re-pack.
    der_sig = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der_sig)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return (signing_input + b"." + _b64url(raw_sig)).decode("ascii")


def _get_jwt(cfg: dict) -> str:
    key_id = cfg.get("key_id", "")
    with _JWT_LOCK:
        now = time.time()
        entry = _jwt_cache.get(key_id)
        if entry and entry["token"] and entry["expires_at"] > now:
            return entry["token"]
        tok = _sign_jwt(cfg)
        _jwt_cache[key_id] = {"token": tok, "expires_at": now + _JWT_TTL}
        return tok


def _build_apns_body(payload: dict, alert: Optional[dict]) -> dict:
    """APS body. With an alert -> visible (banner) push; without -> silent."""
    aps: dict = {}
    if alert:
        aps["alert"] = {"title": alert.get("title", ""), "body": alert.get("body", "")}
        aps["sound"] = "default"
        # An actionable notification: iOS shows the category's buttons
        # (Approve/Deny/Reply) on the banner/lock screen.
        cat = alert.get("category")
        if cat:
            aps["category"] = str(cat)
    else:
        # content-available:1 + no alert = silent / background push.
        aps["content-available"] = 1
    # Custom envelope: read in didReceiveRemoteNotification for a SILENT push;
    # for a visible (alert) push it rides along and is available on tap.
    return {"aps": aps, "jarviscopilot": payload or {}}


def _apns_headers(cfg: dict, jwt: str, *, alert: bool,
                  topic: Optional[str] = None) -> dict:
    return {
        "authorization": f"bearer {jwt}",
        # The JWT is signed with team-wide credentials, so one auth key covers every
        # bundle ID under the team — only this header is per-app. That lets a second
        # native client (JarvisWearables) register its own topic instead of the
        # config's single default.
        "apns-topic": topic or cfg["topic"],
        # 'alert' push shows a banner + can launch the app on tap; 'background'
        # is silent. Visible pushes use priority 10; silent ones MUST use 5.
        "apns-push-type": "alert" if alert else "background",
        "apns-priority": "10" if alert else "5",
        # Visible push survives ~1h so a later tap still finds it; silent expires now.
        "apns-expiration": str(int(time.time()) + 3600) if alert else "0",
        "content-type": "application/json",
    }


def send_apns(push_token: str, payload: dict, *, timeout: float = 10.0,
              alert: Optional[dict] = None, topic: Optional[str] = None,
              sandbox: Optional[bool] = None) -> dict:
    """POST a push to APNs HTTP/2.

    ``payload`` is merged into the data envelope. With ``alert`` (title/body)
    it's a VISIBLE, tappable banner; without, a silent "background notification"
    that wakes the app for ~30s with no banner.

    ``topic`` overrides the configured bundle ID for this send, so devices running a
    different app of ours can be reached with the same auth key. ``sandbox`` overrides
    the APNs host for that device's signing environment.
    """
    cfg = _config_for(topic)
    if not cfg:
        return {"ok": False, "error": "APNs config missing or invalid"}
    if not Path(cfg["_key_path"]).exists():
        return {"ok": False, "error": "APNs auth key not configured"}
    if not _have_httpx():
        return {"ok": False, "error": "APNs requires httpx[http2]"}

    try:
        jwt = _get_jwt(cfg)
    except Exception as exc:
        logger.warning("APNs JWT sign failed: %s", exc)
        return {"ok": False, "error": f"APNs JWT: {exc}"}

    body = _build_apns_body(payload, alert)
    # A token's environment is fixed by the signing entitlement of the app that
    # produced it: development-signed apps get sandbox-only tokens. With two clients
    # on one team — one distribution-signed, one development — a single global flag
    # can't serve both, so the device's own environment wins when it reports one.
    use_sandbox = bool(cfg.get("use_sandbox")) if sandbox is None else bool(sandbox)
    host = "api.sandbox.push.apple.com" if use_sandbox else "api.push.apple.com"
    url = f"https://{host}/3/device/{push_token}"
    headers = _apns_headers(cfg, jwt, alert=bool(alert), topic=topic)
    try:
        r = _apns_post(url, headers, json.dumps(body), timeout)
        if r.status_code == 200:
            return {"ok": True}
        return {
            "ok": False,
            "error": f"APNs HTTP {r.status_code}: {r.text[:200]}",
            "status": r.status_code,
        }
    except Exception as exc:
        return {"ok": False, "error": f"APNs send: {exc}"}


# ── Live Activity push (ActivityKit) ─────────────────────────────────────────
# A Live Activity has its OWN push token (separate from the device push token);
# the app reports it via /api/coding/la-token. The push-type is "liveactivity"
# and the topic gets a ".push-type.liveactivity" suffix; the body's
# aps.content-state must match the Swift ContentState's Codable keys exactly.


def la_topic(cfg: dict) -> str:
    return f"{cfg['topic']}.push-type.liveactivity"


def _apns_la_headers(cfg: dict, jwt: str, *, priority: int) -> dict:
    return {
        "authorization": f"bearer {jwt}",
        "apns-topic": la_topic(cfg),
        "apns-push-type": "liveactivity",
        "apns-priority": str(priority),
        "apns-expiration": "0",
        "content-type": "application/json",
    }


def build_la_aps(content_state: dict, *, event: str = "update",
                 stale_after: Optional[int] = None,
                 dismissal_after: Optional[int] = None,
                 now: Optional[int] = None) -> dict:
    """The ``aps`` dict for a Live Activity update/end push."""
    ts = int(time.time()) if now is None else int(now)
    aps: dict = {"timestamp": ts, "event": event,
                 "content-state": content_state or {}}
    if stale_after is not None:
        aps["stale-date"] = ts + int(stale_after)
    if event == "end" and dismissal_after is not None:
        aps["dismissal-date"] = ts + int(dismissal_after)
    return aps


def send_live_activity(push_token: str, content_state: dict, *,
                       event: str = "update", timeout: float = 10.0,
                       priority: int = 10,
                       stale_after: Optional[int] = 3600) -> dict:
    """Push a Live Activity content-state update (or ``event="end"``) via APNs."""
    if not _KEY_FILE.exists():
        return {"ok": False, "error": "APNs auth key not configured"}
    cfg = _load_config()
    if not cfg:
        return {"ok": False, "error": "APNs config missing or invalid"}
    if not _have_httpx():
        return {"ok": False, "error": "APNs requires httpx[http2]"}
    try:
        jwt = _get_jwt(cfg)
    except Exception as exc:
        logger.warning("APNs JWT sign failed: %s", exc)
        return {"ok": False, "error": f"APNs JWT: {exc}"}

    body = {"aps": build_la_aps(content_state, event=event,
                                stale_after=stale_after)}
    use_sandbox = bool(cfg.get("use_sandbox"))
    host = "api.sandbox.push.apple.com" if use_sandbox else "api.push.apple.com"
    url = f"https://{host}/3/device/{push_token}"
    headers = _apns_la_headers(cfg, jwt, priority=priority)
    try:
        r = _apns_post(url, headers, json.dumps(body), timeout)
        if r.status_code == 200:
            return {"ok": True}
        return {
            "ok": False,
            "error": f"APNs HTTP {r.status_code}: {r.text[:200]}",
            "status": r.status_code,
        }
    except Exception as exc:
        return {"ok": False, "error": f"APNs send: {exc}"}
