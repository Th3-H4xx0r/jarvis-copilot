"""Sunshine local-API client: paired clients, apps, pairing PIN, restart.

Talks to Sunshine's web API (default https://<pc>:47990) with HTTP Basic auth
and a CSRF token for state-changing calls. stdlib only (urllib + ssl) to keep
jc-client light. Connection/auth failures raise SunshineUnavailable so callers
surface a clean "Sunshine down" instead of crashing.

Pairing (verified live against Sunshine's own web UI, 2026-11-21): a Moonlight
client that starts pairing shows a 4-digit PIN and appears in GET /api/pin as
{"pairings": [{"id": <32 hex>, "name", "address"}]}; POST /api/pin with
{"pairing_id", "pin", "name"} answers 200 {"status": true|false} (false = wrong
PIN or unknown id). GET /api/csrf-token answers {"csrf_token": "..."}, sent back
as the X-CSRF-Token header.
"""
from __future__ import annotations

import base64
import json
import socket
import ssl
import urllib.error
import urllib.request


class SunshineUnavailable(RuntimeError):
    """Sunshine's API could not be reached or rejected our credentials."""


class SunshineAuthError(SunshineUnavailable):
    """Sunshine answered but rejected our credentials (401/403): it is running, it
    just needs a valid login. A subclass so existing except-SunshineUnavailable
    callers keep treating it as down."""


class SunshineError(RuntimeError):
    """Sunshine answered but refused the request (e.g. HTTP 400 with {"error": ...}).
    It is running, so this is deliberately NOT a SunshineUnavailable."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class SunshineCsrfError(SunshineError):
    """Sunshine refused a state change over its CSRF token (missing/invalid/expired)."""


_CSRF_ERRORS = {"Missing CSRF token", "Invalid CSRF token", "CSRF token expired"}


def _http_error_message(e):
    try:
        body = json.loads(e.read().decode() or "{}")
    except Exception:  # noqa: BLE001
        body = {}
    msg = body.get("error") if isinstance(body, dict) else None
    return str(msg or f"HTTP {e.code}")


class SunshineClient:
    def __init__(self, host, port, user, password, scheme="https",
                 verify_tls=False, timeout=5.0):
        self.base = f"{scheme}://{host}:{port}"
        self._timeout = timeout
        self._auth = "Basic " + base64.b64encode(
            f"{user}:{password}".encode()).decode()
        if scheme == "https" and not verify_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self._ctx = ctx
        else:
            self._ctx = None

    def _open(self, req):
        kw = {"timeout": self._timeout}
        if self._ctx is not None:
            kw["context"] = self._ctx
        try:
            with urllib.request.urlopen(req, **kw) as resp:
                raw = resp.read().decode() or "{}"
            return json.loads(raw)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise SunshineAuthError(f"auth failed ({e.code})") from e
            msg = _http_error_message(e)
            if msg in _CSRF_ERRORS:
                raise SunshineCsrfError(e.code, msg) from e
            raise SunshineError(e.code, msg) from e
        except (urllib.error.URLError, OSError, socket.timeout) as e:
            raise SunshineUnavailable(str(e)) from e

    def _get(self, path):
        req = urllib.request.Request(self.base + path, method="GET")
        req.add_header("Authorization", self._auth)
        return self._open(req)

    def _csrf(self):
        return self._get("/api/csrf-token").get("csrf_token", "")

    def _post(self, path, body):
        token = self._csrf()
        data = json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST")
        req.add_header("Authorization", self._auth)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-CSRF-Token", token)
        return self._open(req)

    # ── reads ────────────────────────────────────────────────────────────
    def reachable(self):
        try:
            self._get("/api/clients/list")
            return True
        except SunshineUnavailable:
            return False

    def probe(self):
        """Detect for setup: is Sunshine running, and are the credentials good?
        Distinguishes not-running (connection refused/timeout) from running-but-the-
        login-is-missing/wrong (401/403), which the status probe cannot tell apart."""
        try:
            self._get("/api/clients/list")
        except SunshineAuthError:
            return {"running": True, "needs_login": True}
        except SunshineUnavailable:
            return {"running": False, "needs_login": False}
        return {"running": True, "needs_login": False}

    def get_clients(self):
        return self._get("/api/clients/list").get("named_certs", [])

    def get_apps(self):
        return self._get("/api/apps").get("apps", [])

    def get_config(self):
        return self._get("/api/config")

    def pending_pairings(self):
        """Pair requests waiting for a PIN: [{"id", "name", "address"}] (Sunshine's own
        web UI polls this every 2 s)."""
        raw = self._get("/api/pin").get("pairings") or []
        return [p for p in raw if isinstance(p, dict) and p.get("id")]

    # ── state changes (CSRF-guarded) ─────────────────────────────────────
    def submit_pin(self, pin, name=None, pairing_id=None):
        """Answer one pending pair request. True when Sunshine accepted the PIN; False
        for a wrong PIN or an id that is no longer pending (Sunshine answers 200 with
        status false for both)."""
        resp = self._post("/api/pin", {"pairing_id": pairing_id or "", "pin": pin,
                                       "name": name or ""})
        return resp.get("status") is True

    def unpair(self, uuid):
        self._post("/api/clients/unpair", {"uuid": uuid})

    def close_app(self):
        self._post("/api/apps/close", {})

    def restart(self):
        self._post("/api/restart", {})
