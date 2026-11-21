"""Sunshine local-API client: paired clients, apps, pairing PIN, restart.

Talks to Sunshine's web API (default https://<pc>:47990) with HTTP Basic auth
and a CSRF token for state-changing calls. stdlib only (urllib + ssl) to keep
jc-client light. Connection/auth failures raise SunshineUnavailable so callers
surface a clean "Sunshine down" instead of crashing.

NOTE (verify live): the pairing payload shape ({"pin","name"}) and the CSRF
header name ("X-CSRF-Token") follow Sunshine's API docs; confirm against the
running build and adjust if it rejects them.
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
                raise SunshineUnavailable(f"auth failed ({e.code})") from e
            raise
        except (urllib.error.URLError, OSError, socket.timeout) as e:
            raise SunshineUnavailable(str(e)) from e

    def _get(self, path):
        req = urllib.request.Request(self.base + path, method="GET")
        req.add_header("Authorization", self._auth)
        return self._open(req)

    def _csrf(self):
        return self._get("/api/csrf-token").get("token", "")

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

    def get_clients(self):
        return self._get("/api/clients/list").get("named_certs", [])

    def get_apps(self):
        return self._get("/api/apps").get("apps", [])

    def get_config(self):
        return self._get("/api/config")

    # ── state changes (CSRF-guarded) ─────────────────────────────────────
    def submit_pin(self, pin, name=None):
        resp = self._post("/api/pin", {"pin": pin, "name": name or ""})
        return bool(resp.get("status", True))

    def unpair(self, uuid):
        self._post("/api/clients/unpair", {"uuid": uuid})

    def close_app(self):
        self._post("/api/apps/close", {})

    def restart(self):
        self._post("/api/restart", {})
