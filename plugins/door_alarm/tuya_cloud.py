"""Tuya's documented cloud OpenAPI, signed with Pranav's own developer project (access ID + secret).

Used once at setup (device list, data-point model, the hub's local key) and afterwards for commands
when the ESP32 proxy is down, device info, rename and firmware. Never Smart Life's private
``thing.m.*`` app API. Signing follows developer.tuya.com "Sign requests" (HMAC-SHA256 over
client_id [+ access_token] + t + nonce + METHOD\\nSHA256(body)\\n<headers>\\n<path?sorted query>).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Callable, Optional

_REGIONS = {
    "us": "https://openapi.tuyaus.com",          # Western America
    "us-e": "https://openapi-ueaz.tuyaus.com",   # Eastern America
    "eu": "https://openapi.tuyaeu.com",          # Central Europe
    "eu-w": "https://openapi-weaz.tuyaeu.com",   # Western Europe
    "in": "https://openapi.tuyain.com",
    "cn": "https://openapi.tuyacn.com",
    "sg": "https://openapi-sg.iotbing.com",
}

# Codes that mean "these credentials can't do this" — retrying won't help; Pranav has to act
# (wrong id/secret, app account not linked, lapsed free subscription, API not authorised).
_AUTH_CODES = {1004, 1005, 1010, 1011, 1012, 1013, 1106, 1107, 2017, 28841002, 28841101, 28841105}
_TOKEN_INVALID = {1010, 1011}
_AUTH_WORDS = ("sign invalid", "permission deny", "subscription", "expired", "not authorized", "clientid")


class TuyaError(Exception):
    """``kind``: ``auth`` (credentials / subscription — needs Pranav), ``transient`` (network, 5xx —
    retry later) or ``refused`` (Tuya understood and said no: bad value, unsupported)."""

    def __init__(self, message: str, kind: str, code: Any = None) -> None:
        super().__init__(message)
        self.kind = kind
        self.code = code


def base_url(region: str) -> str:
    try:
        return _REGIONS[(region or "").strip().lower()]
    except KeyError:
        raise ValueError(f"Unknown Tuya region {region!r}; use one of {', '.join(_REGIONS)}") from None


def regions() -> list[str]:
    return list(_REGIONS)


def _urllib_transport(method: str, url: str, headers: dict, body: Optional[str], timeout: float):
    req = urllib.request.Request(url, data=body.encode() if body else None, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode() or "null")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode() or "null")
        except ValueError:
            return exc.code, None


class TuyaCloud:
    def __init__(self, access_id: str, access_secret: str, base: str, *,
                 transport: Callable | None = None, clock: Callable[[], float] = time.time,
                 nonce: Callable[[], str] | None = None, timeout: float = 12.0) -> None:
        self.access_id = access_id
        self._secret = access_secret
        self.base = base.rstrip("/")
        self._transport = transport or _urllib_transport
        self._clock = clock
        self._nonce = nonce or (lambda: uuid.uuid4().hex)
        self._timeout = timeout
        self._token: Optional[str] = None
        self._token_expires = 0.0
        self.uid: Optional[str] = None
        self._lock = threading.Lock()

    def __repr__(self) -> str:
        return f"TuyaCloud(access_id={self.access_id!r}, base={self.base!r})"

    # ── signing ──

    @staticmethod
    def _sign_path(path: str, query: Optional[dict]) -> str:
        if not query:
            return path
        return path + "?" + "&".join(f"{k}={query[k]}" for k in sorted(query))

    def _sign(self, method: str, path_query: str, body: str, token: Optional[str], t: str, nonce: str) -> str:
        string_to_sign = f"{method}\n{hashlib.sha256(body.encode()).hexdigest()}\n\n{path_query}"
        msg = self.access_id + (token or "") + t + nonce + string_to_sign
        return hmac.new(self._secret.encode(), msg.encode(), hashlib.sha256).hexdigest().upper()

    def _send(self, method: str, path: str, query: Optional[dict], body_obj: Any, token: Optional[str]) -> dict:
        body = json.dumps(body_obj, separators=(",", ":")) if body_obj is not None else ""
        path_query = self._sign_path(path, query)
        t = str(int(self._clock() * 1000))
        nonce = self._nonce()
        headers = {"client_id": self.access_id, "t": t, "sign_method": "HMAC-SHA256",
                   "sign": self._sign(method, path_query, body, token, t, nonce)}
        if nonce:
            headers["nonce"] = nonce
        if token:
            headers["access_token"] = token
        if body:
            headers["Content-Type"] = "application/json"
        url = self.base + (path + "?" + urllib.parse.urlencode(sorted(query.items())) if query else path)
        try:
            status, data = self._transport(method, url, headers, body or None, self._timeout)
        except (OSError, TimeoutError, ValueError) as exc:
            raise TuyaError(f"Couldn't reach Tuya's cloud ({exc}).", "transient") from exc
        if status >= 500 or not isinstance(data, dict):
            raise TuyaError(f"Tuya's cloud answered HTTP {status}.", "transient", status)
        return data

    @staticmethod
    def _classify(data: dict) -> TuyaError:
        code = data.get("code")
        msg = str(data.get("msg") or "Tuya refused the request")
        try:
            code_i = int(code)
        except (TypeError, ValueError):
            code_i = None
        lower = msg.lower()
        if code_i in _AUTH_CODES or any(w in lower for w in _AUTH_WORDS):
            return TuyaError(f"Tuya: {msg}", "auth", code_i if code_i is not None else code)
        return TuyaError(f"Tuya: {msg}", "refused", code_i if code_i is not None else code)

    # ── token ──

    def _ensure_token(self) -> str:
        with self._lock:
            if self._token and self._clock() < self._token_expires - 60:
                return self._token
            data = self._send("GET", "/v1.0/token", {"grant_type": 1}, None, None)
            if not data.get("success"):
                raise self._classify(data)
            result = data.get("result") or {}
            self._token = str(result.get("access_token") or "")
            self._token_expires = self._clock() + float(result.get("expire_time") or 3600)
            self.uid = result.get("uid") or self.uid
            if not self._token:
                raise TuyaError("Tuya gave no access token.", "auth")
            return self._token

    def request(self, method: str, path: str, query: Optional[dict] = None, body: Any = None) -> Any:
        """A signed business call; returns ``result``. Retries once with a new token if Tuya says
        the token is invalid."""
        for attempt in (0, 1):
            data = self._send(method, path, query, body, self._ensure_token())
            if data.get("success"):
                return data.get("result")
            err = self._classify(data)
            if attempt == 0 and err.code in _TOKEN_INVALID:
                with self._lock:
                    self._token = None
                continue
            raise err
        raise TuyaError("Tuya kept rejecting the token.", "auth")

    # ── endpoints ──

    def devices(self) -> list[dict]:
        """Every device of the Smart Life accounts linked to the project."""
        out: list[dict] = []
        query: dict = {"size": 50}
        for _ in range(40):
            result = self.request("GET", "/v1.0/iot-01/associated-users/devices", dict(query)) or {}
            out += list(result.get("devices") or result.get("list") or [])
            if not result.get("has_more") or not result.get("last_row_key"):
                break
            query["last_row_key"] = result["last_row_key"]
        return out

    def device(self, dev_id: str) -> dict:
        """Details incl. ``local_key``, public ``ip``, ``online``, ``product_id``, ``category``."""
        return self.request("GET", f"/v1.0/devices/{_q(dev_id)}") or {}

    def specifications(self, dev_id: str) -> dict:
        """``{category, functions:[{dp_id, code, type, values}], status:[...]}``."""
        return self.request("GET", f"/v1.1/devices/{_q(dev_id)}/specifications") or {}

    def model(self, dev_id: str) -> dict:
        """The thing model (every data point with its id, code, type and access mode)."""
        result = self.request("GET", f"/v2.0/cloud/thing/{_q(dev_id)}/model") or {}
        raw = result.get("model") if isinstance(result, dict) else None
        if isinstance(raw, str):
            return json.loads(raw)
        return raw if isinstance(raw, dict) else {}

    def properties(self, dev_id: str) -> list[dict]:
        """Current values: ``[{dp_id, code, value, time}]``."""
        result = self.request("GET", f"/v2.0/cloud/thing/{_q(dev_id)}/shadow/properties") or {}
        return list(result.get("properties") or []) if isinstance(result, dict) else []

    def issue(self, dev_id: str, values: dict) -> Any:
        """Write data points by code (works for every DP, standard or not)."""
        return self.request("POST", f"/v2.0/cloud/thing/{_q(dev_id)}/shadow/properties/issue",
                            body={"properties": json.dumps(values, separators=(",", ":"))})

    def rename(self, dev_id: str, name: str) -> Any:
        return self.request("PUT", f"/v1.0/iot-03/devices/{_q(dev_id)}", body={"name": name})

    def firmware(self, dev_id: str) -> list[dict]:
        """Firmware modules with current/upgrade versions (best effort — not every project has it)."""
        result = self.request("GET", f"/v2.0/cloud/thing/{_q(dev_id)}/firmware")
        if isinstance(result, dict):
            return list(result.get("firmwares") or result.get("list") or [result])
        return list(result or [])

    def upgrade(self, dev_id: str, firmware_id: Any) -> Any:
        return self.request("POST", f"/v2.0/cloud/thing/{_q(dev_id)}/firmware/{_q(str(firmware_id))}")


def _q(part: str) -> str:
    return urllib.parse.quote(str(part), safe="")
