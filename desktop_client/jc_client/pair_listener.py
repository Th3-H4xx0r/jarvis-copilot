"""QR pairing for computers (docs/superpowers/specs/2026-11-23-qr-pairing-design.md,
contract in docs/superpowers/plans/2026-11-23-qr-pairing.md).

Unpaired, the computer can't reach the server (Cloudflare Access), so his iPhone hands it the pairing over the home
network: the Jarvis app shows a QR (``jarvis://pair-computer?…``) with this machine's LAN address and a one-time key;
the phone gets a code from the server, seals {server, code, Cloudflare token} with AES-256-GCM and POSTs it to the
one-time listener here, which pairs exactly like ``jc-client pair --code`` and closes.
"""
from __future__ import annotations

import base64
import http.server
import json
import logging
import secrets
import socket
import sys
import threading
import time
import urllib.parse
from typing import Callable, Optional

log = logging.getLogger(__name__)

AAD = b"jarvis-pair-computer-v1"
PREFERRED_PORT = 47913          # one firewall rule on Windows (installer); any free port if it's taken
LIFETIME_S = 600.0
MAX_AGE_S = 120.0


class PairError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def build_payload(host: str, port: int, key: bytes, name: str, os_name: str) -> str:
    q = urllib.parse.quote
    return (f"jarvis://pair-computer?v=1&host={host}&port={int(port)}&key={_b64u(key)}"
            f"&name={q(name, safe='')}&os={os_name}")


def key_from_payload(payload: str) -> bytes:
    qs = urllib.parse.parse_qs(urllib.parse.urlparse(payload).query)
    k = qs["key"][0]
    return base64.urlsafe_b64decode(k + "=" * (-len(k) % 4))


def open_hand_off(key: bytes, body: dict, *, now: Optional[float] = None) -> dict:
    """Decrypt and check the phone's hand-off. Raises PairError(status, why)."""
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    try:
        nonce = base64.b64decode(str(body.get("nonce") or ""))
        ct = base64.b64decode(str(body.get("ct") or ""))
    except (ValueError, TypeError) as exc:
        raise PairError(400, "bad request") from exc
    if body.get("v") != 1 or len(nonce) != 12 or len(ct) < 17:
        raise PairError(400, "bad request")
    try:
        plain = json.loads(AESGCM(key).decrypt(nonce, ct, AAD).decode("utf-8"))
    except InvalidTag as exc:
        raise PairError(401, "This QR code is for another pairing. Scan the one on the screen now.") from exc
    except ValueError as exc:
        raise PairError(400, "bad request") from exc
    if not isinstance(plain, dict) or not plain.get("server") or not plain.get("code"):
        raise PairError(400, "bad request")
    try:
        age = abs((now if now is not None else time.time()) - float(plain.get("ts") or 0))
    except (TypeError, ValueError):
        age = MAX_AGE_S + 1
    if age > MAX_AGE_S:
        raise PairError(409, "That pairing is too old. Scan again.")
    return plain


def lan_ip() -> str:
    """This machine's address on the home network (the interface its default route uses; nothing is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.0.1", 9))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def claim(server: str, code: str, name: str, cf_id: str = "", cf_secret: str = "") -> dict:
    """Pair with a code (the same steps as ``jc-client pair --code``). {"ok", "device_name"} or {"ok": False, "error"}."""
    from jc_client import credentials
    from jc_client.protocol import HttpClient
    url = server.rstrip("/")
    name = name or socket.gethostname()
    try:
        client = HttpClient(url, expected_fingerprint="", cf_client_id=cf_id, cf_client_secret=cf_secret)
        resp, fingerprint = client.post_json("/api/auth/pair/claim", {"code": code, "name": name})
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"Couldn't reach {url}: {exc}"}
    if resp.status != 200 or not resp.cookie:
        err = resp.json().get("error") if resp.body else None
        return {"ok": False, "error": f"The server said no ({resp.status}): {err or 'unknown'}"}
    creds = credentials.load()
    creds.server_url = url
    creds.device_name = name
    creds.cookie = resp.cookie
    creds.cert_fingerprint = fingerprint
    creds.cf_client_id, creds.cf_client_secret = cf_id, cf_secret
    cf = resp.json().get("cf_access") if resp.body else None
    if isinstance(cf, dict):
        creds.cf_client_id = str(cf.get("client_id") or "")
        creds.cf_client_secret = str(cf.get("client_secret") or "")
    if not creds.device_id:
        import uuid
        creds.device_id = uuid.uuid4().hex
    credentials.save(creds)
    return {"ok": True, "device_name": name}


class PairListener:
    """One QR's worth of listening: one success, LIFETIME_S at most, each sealed request at most once."""

    def __init__(self, claim_fn: Callable[..., dict], *, name: str, os_name: str, host: str = "",
                 port: int = PREFERRED_PORT, on_state: Callable[..., None] = lambda state, **kw: None,
                 lifetime_s: float = LIFETIME_S) -> None:
        self._claim, self._name, self._os = claim_fn, name, os_name
        self._host, self._port, self._on_state, self._life = host, port, on_state, lifetime_s
        self._key = secrets.token_bytes(32)
        self._seen: set = set()
        self._done = False
        self._lock = threading.Lock()
        self._server: Optional[http.server.ThreadingHTTPServer] = None
        self._timer: Optional[threading.Timer] = None

    def start(self) -> dict:
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):   # keep the codes out of the log
                pass

            def _reply(self, status: int, payload: dict) -> None:
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):  # noqa: N802
                if self.path != "/pair":
                    return self._reply(404, {"ok": False, "error": "not found"})
                n = min(int(self.headers.get("Content-Length") or 0), 8192)
                try:
                    body = json.loads(self.rfile.read(n) or b"{}")
                except ValueError:
                    return self._reply(400, {"ok": False, "error": "bad request"})
                status, payload = outer._handle(body if isinstance(body, dict) else {})
                self._reply(status, payload)
                if payload.get("ok"):
                    threading.Thread(target=outer.stop, daemon=True).start()

        bind = "127.0.0.1" if self._host == "127.0.0.1" else "0.0.0.0"
        try:
            self._server = http.server.ThreadingHTTPServer((bind, self._port), Handler)
        except OSError:
            self._server = http.server.ThreadingHTTPServer((bind, 0), Handler)
        port = self._server.server_address[1]
        threading.Thread(target=self._server.serve_forever, name="jc-pair-listener", daemon=True).start()
        self._timer = threading.Timer(self._life, self._expire)
        self._timer.daemon = True
        self._timer.start()
        host = self._host or lan_ip()
        self._on_state("waiting")
        return {"ok": True, "payload": build_payload(host, port, self._key, self._name, self._os),
                "expires_at": int(time.time() + self._life), "host": host, "port": port}

    def _handle(self, body: dict) -> tuple:
        with self._lock:
            if self._done:
                return 409, {"ok": False, "error": "This computer is already paired. Scan a new code."}
            sealed = str(body.get("nonce") or "") + ":" + str(body.get("ct") or "")[:64]
            if sealed in self._seen:
                return 409, {"ok": False, "error": "That pairing was already used. Scan again."}
            self._seen.add(sealed)
        try:
            plain = open_hand_off(self._key, body)
        except PairError as exc:
            return exc.status, {"ok": False, "error": str(exc)}
        self._on_state("pairing")
        out = self._claim(str(plain["server"]), str(plain["code"]), self._name,
                          str(plain.get("cf_id") or ""), str(plain.get("cf_secret") or "")) or {}
        if not out.get("ok"):
            self._on_state("error", error=str(out.get("error") or "pairing failed"))
            return 502, {"ok": False, "error": str(out.get("error") or "pairing failed")}
        with self._lock:
            self._done = True
        self._on_state("paired", device_name=str(out.get("device_name") or self._name))
        return 200, {"ok": True, "device_name": str(out.get("device_name") or self._name)}

    def _expire(self) -> None:
        if not self._done:
            self._on_state("expired")
        self.stop()

    def stop(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
        srv, self._server = self._server, None
        if srv is not None:
            try:
                srv.shutdown()
                srv.server_close()
            except OSError:
                pass


class PairController:
    """The Jarvis app's pairing screen talks to this over the local app link (service._ui_request)."""

    KINDS = frozenset({"pair_status", "pair_qr_start", "pair_manual"})

    def __init__(self, broadcast: Callable[[dict], None], *, claim: Callable[..., dict] = claim,
                 load: Optional[Callable] = None) -> None:
        self._broadcast, self._claim = broadcast, claim
        if load is None:
            from jc_client import credentials
            load = credentials.load
        self._load = load
        self._listener: Optional[PairListener] = None

    def _state(self, state: str, **kw) -> None:
        self._broadcast({"type": "pair_state", "state": state, **kw})

    def handle(self, req: dict) -> dict:
        kind = req.get("type")
        creds = self._load()
        name = creds.device_name or socket.gethostname()
        if kind == "pair_status":
            return {"ok": True, "paired": bool(creds.paired), "server": creds.server_url or "", "device_name": name}
        if kind == "pair_qr_start":
            if self._listener is not None:
                self._listener.stop()
            self._listener = PairListener(self._claim, name=name,
                                          os_name="windows" if sys.platform == "win32" else "macos",
                                          on_state=self._state)
            return self._listener.start()
        if kind == "pair_manual":
            server, code = str(req.get("server") or "").strip(), str(req.get("code") or "").strip()
            if not server or not code:
                return {"ok": False, "error": "Enter the server address and the code."}
            self._state("pairing")
            out = self._claim(server, code, name, str(req.get("cf_id") or ""), str(req.get("cf_secret") or "")) or {}
            if out.get("ok"):
                self._state("paired", device_name=str(out.get("device_name") or name))
                return {"ok": True}
            self._state("error", error=str(out.get("error") or "pairing failed"))
            return {"ok": False, "error": str(out.get("error") or "pairing failed")}
        return {"ok": False, "error": "unknown request"}
