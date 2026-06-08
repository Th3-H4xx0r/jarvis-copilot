"""WebSocket + HTTP protocol wrapper for the desktop client.

Sync I/O on top of stdlib ``socket``/``ssl`` + ``wsproto``. We use sync
because the daemon runs a single connection and a small thread pool for
skill execution — asyncio would add complexity without buying anything.

Two public classes:

- ``HttpClient`` — does the one-shot ``POST /api/auth/pair/claim``
  during pairing, with TLS-fingerprint pinning.
- ``WsConnection`` — long-lived WS bridge. ``connect()`` handshake +
  fingerprint check. ``send_text()`` is thread-safe (one writer + many
  worker threads sending results). ``read_frames()`` is the receive
  generator the service loop iterates.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import secrets
import socket
import ssl
import threading
import time
from dataclasses import dataclass
from typing import Iterator, Optional
from urllib.parse import urlparse

from wsproto import ConnectionType, WSConnection
from wsproto.events import (
    AcceptConnection,
    BytesMessage,
    CloseConnection,
    Ping,
    Pong,
    RejectConnection,
    Request,
    TextMessage,
)

log = logging.getLogger(__name__)

# Read chunk size for the WS pump. wsproto handles framing; we only need
# to keep the kernel buffer drained.
_RECV_CHUNK = 8192
_DEFAULT_HTTP_TIMEOUT = 30.0
_DEFAULT_CONNECT_TIMEOUT = 15.0


def _split_url(url: str) -> tuple[str, int, str, str]:
    """Parse a webui URL → (host, port, scheme, path_prefix). Strips
    trailing slash from the prefix so we can safely concatenate paths."""
    p = urlparse(url)
    if p.scheme not in ("http", "https"):
        raise ValueError(f"unsupported scheme: {p.scheme!r}")
    host = p.hostname or ""
    if not host:
        raise ValueError(f"missing host in URL: {url!r}")
    port = p.port or (443 if p.scheme == "https" else 80)
    prefix = (p.path or "").rstrip("/")
    return host, port, p.scheme, prefix


def _make_ssl_context() -> ssl.SSLContext:
    """Build a context that does the TLS handshake but lets us verify
    the fingerprint ourselves. ``check_hostname=False`` + ``CERT_NONE``
    is safe **because** we always pin the leaf cert SHA-256."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def cert_fingerprint(sock: ssl.SSLSocket) -> str:
    """SHA-256 hex of the peer's DER cert (no separators)."""
    der = sock.getpeercert(binary_form=True)
    if not der:
        raise ssl.SSLError("server presented no certificate")
    return hashlib.sha256(der).hexdigest()


def _verify_fingerprint(sock: ssl.SSLSocket, expected: str) -> None:
    """Raise ssl.SSLError if the peer cert doesn't match expected SHA-256."""
    if not expected:
        return  # caller chose not to pin (first-pair only)
    actual = cert_fingerprint(sock)
    if actual.lower() != expected.lower():
        raise ssl.SSLError(
            f"TLS cert fingerprint mismatch: expected {expected}, got {actual}"
        )


# ── HTTP ───────────────────────────────────────────────────────────────────

@dataclass
class HttpResponse:
    status: int
    headers: dict[str, str]
    body: bytes

    def json(self) -> dict:
        if not self.body:
            return {}
        try:
            return json.loads(self.body.decode("utf-8", "replace"))
        except Exception:
            return {}

    @property
    def cookie(self) -> str:
        """Value of the ``hermes_session=<...>; ...`` cookie header,
        or "" if none was set."""
        raw = self.headers.get("set-cookie", "")
        # Multiple Set-Cookie headers can come in; we only need the one
        # whose name is the auth cookie.
        for part in raw.split(","):
            seg = part.strip()
            if seg.lower().startswith("hermes_session="):
                return seg.split(";", 1)[0]  # "hermes_session=abc.def"
        return ""


class HttpClient:
    """Tiny HTTP/1.1 client just sufficient for the pairing POST.

    We could use urllib here, but doing the socket dance ourselves means
    we get to call ``cert_fingerprint()`` BEFORE sending the request —
    so a pinned host that's been swapped never sees our bytes.
    """

    def __init__(self, server_url: str, cookie: str = "", expected_fingerprint: str = "",
                 cf_client_id: str = "", cf_client_secret: str = ""):
        self.server_url = server_url
        self.cookie = cookie
        self.expected_fingerprint = expected_fingerprint
        self.cf_client_id = cf_client_id
        self.cf_client_secret = cf_client_secret
        self._host, self._port, self._scheme, self._prefix = _split_url(server_url)

    def _cf_header_lines(self) -> list[str]:
        """CF-Access service-token header lines, or [] when not configured."""
        if self.cf_client_id and self.cf_client_secret:
            return [
                f"CF-Access-Client-Id: {self.cf_client_id}",
                f"CF-Access-Client-Secret: {self.cf_client_secret}",
            ]
        return []

    def _connect(self) -> tuple[socket.socket, str]:
        """Open TCP + TLS, verify fingerprint, return (sock, observed_fingerprint)."""
        sock = socket.create_connection(
            (self._host, self._port), timeout=_DEFAULT_CONNECT_TIMEOUT
        )
        observed = ""
        if self._scheme == "https":
            ctx = _make_ssl_context()
            sock = ctx.wrap_socket(sock, server_hostname=self._host)
            observed = cert_fingerprint(sock)
            _verify_fingerprint(sock, self.expected_fingerprint)
        sock.settimeout(_DEFAULT_HTTP_TIMEOUT)
        return sock, observed

    def post_json(self, path: str, body: dict) -> tuple[HttpResponse, str]:
        """POST a JSON body. Returns (response, observed_fingerprint).

        The observed fingerprint is the leaf-cert SHA-256 we saw on this
        connection — the pair UI uses it to decide whether to pin.
        """
        full_path = self._prefix + path
        payload = json.dumps(body).encode("utf-8")
        lines = [
            f"POST {full_path} HTTP/1.1",
            f"Host: {self._host}:{self._port}",
            "User-Agent: jc-client/0.1",
            "Content-Type: application/json",
            f"Content-Length: {len(payload)}",
            "Accept: application/json",
            "X-Requested-With: jc-client",
        ]
        # CF-Access service-token headers MUST go on the pair-claim POST too —
        # this is the first request to a tunnel-fronted server, so without them
        # Cloudflare Access 302-redirects it to the SSO login before it ever
        # reaches the origin. (post_json is separate from request_json, which is
        # why it needs its own copy of these header lines.)
        lines.extend(self._cf_header_lines())
        lines.append("Connection: close")
        req = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + payload

        sock, observed = self._connect()
        try:
            sock.sendall(req)
            raw = b""
            while True:
                chunk = sock.recv(_RECV_CHUNK)
                if not chunk:
                    break
                raw += chunk
        finally:
            try:
                sock.close()
            except OSError:
                pass

        return _parse_http_response(raw), observed

    def request_json(self, method: str, path: str, body: dict | None = None) -> "HttpResponse":
        """Pinned HTTP request (GET/POST/…) with the session cookie. JSON body optional."""
        full_path = self._prefix + path
        # NOTE: we intentionally send no Accept-Encoding, so the server replies
        # uncompressed and _parse_http_response (Content-Length / close framing)
        # handles it. Do NOT add gzip here without teaching the parser to decode.
        payload = b"" if body is None else json.dumps(body).encode("utf-8")
        lines = [
            f"{method.upper()} {full_path} HTTP/1.1",
            f"Host: {self._host}:{self._port}",
            "User-Agent: jc-client/0.1",
            "Accept: application/json",
            "X-Requested-With: jc-client",
        ]
        if self.cookie:
            lines.append(f"Cookie: {self.cookie}")
        lines.extend(self._cf_header_lines())
        if body is not None:
            lines.append("Content-Type: application/json")
            lines.append(f"Content-Length: {len(payload)}")
        lines.append("Connection: close")
        req = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + payload
        sock, _ = self._connect()
        try:
            sock.sendall(req)
            raw = b""
            while True:
                chunk = sock.recv(_RECV_CHUNK)
                if not chunk:
                    break
                raw += chunk
        finally:
            try:
                sock.close()
            except OSError:
                pass
        return _parse_http_response(raw)

    def get_sse_event(self, path: str, event_name: str, timeout: float = 180.0):
        """GET a Server-Sent-Events stream and return the JSON ``data`` of the
        first ``event: <event_name>`` block, or None on EOF/timeout. Reads
        incrementally and stops at the match. The webui runs HTTP/1.0 (no chunked
        transfer-encoding), so events are plain ``event:``/``data:`` lines."""
        full_path = self._prefix + path
        lines = [
            f"GET {full_path} HTTP/1.1",
            f"Host: {self._host}:{self._port}",
            "Accept: text/event-stream",
        ]
        if self.cookie:
            lines.append(f"Cookie: {self.cookie}")
        lines.extend(self._cf_header_lines())
        lines.append("Connection: close")
        req = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")
        sock, _ = self._connect()
        try:
            sock.settimeout(timeout)
            sock.sendall(req)
            buf = b""
            while b"\r\n\r\n" not in buf:           # consume + drop the HTTP headers
                chunk = sock.recv(_RECV_CHUNK)
                if not chunk:
                    return None
                buf += chunk
            buf = buf.split(b"\r\n\r\n", 1)[1]
            while True:
                while b"\n\n" in buf:               # one SSE block per \n\n
                    block, buf = buf.split(b"\n\n", 1)
                    ev, data = _parse_sse_block(block.decode("utf-8", "replace"))
                    if ev == event_name:
                        try:
                            return json.loads(data) if data else {}
                        except Exception:
                            return {}
                chunk = sock.recv(_RECV_CHUNK)
                if not chunk:
                    return None
                buf += chunk
        except OSError:                              # includes socket.timeout
            return None
        finally:
            try:
                sock.close()
            except OSError:
                pass


def _parse_sse_block(text: str):
    """Parse one SSE block → (event_name, data_string)."""
    event = ""
    data = []
    for ln in text.splitlines():
        if ln.startswith("event:"):
            event = ln[len("event:"):].strip()
        elif ln.startswith("data:"):
            data.append(ln[len("data:"):].lstrip())
    return event, "\n".join(data)


def _dechunk(body: bytes) -> bytes:
    """Decode an HTTP/1.1 ``Transfer-Encoding: chunked`` body.

    Each chunk is ``<hexsize>[;ext]\\r\\n<data>\\r\\n``; a zero-size chunk ends
    the body (optional trailers follow and are ignored). Best-effort: on any
    malformed length we stop and return what we have, so a partial/odd reply
    degrades instead of raising. ``recv``-until-close in request_json delivers
    the whole framed body (incl. the terminating ``0\\r\\n\\r\\n``), so this
    reassembles it fully.
    """
    out = bytearray()
    i, n = 0, len(body)
    while i < n:
        j = body.find(b"\r\n", i)
        if j == -1:
            break
        size_field = body[i:j].split(b";", 1)[0].strip()  # drop chunk extensions
        try:
            size = int(size_field, 16)
        except ValueError:
            break
        i = j + 2
        if size == 0:
            break  # last chunk; trailers (if any) ignored
        out += body[i:i + size]
        i += size
        if body[i:i + 2] == b"\r\n":  # skip the CRLF after the chunk data
            i += 2
    return bytes(out)


def _parse_http_response(raw: bytes) -> HttpResponse:
    """Bare-minimum HTTP/1.1 parser. Handles Content-Length, chunked
    (``Transfer-Encoding: chunked``), and Connection-close framing. The
    tunnel edge (cloudflared -> nginx) re-chunks large origin responses, so
    chunked decoding is required for big bodies like a full session handoff."""
    head, _, rest = raw.partition(b"\r\n\r\n")
    head_text = head.decode("iso-8859-1", "replace")
    lines = head_text.split("\r\n")
    if not lines:
        return HttpResponse(0, {}, b"")
    status_line = lines[0]
    parts = status_line.split(" ", 2)
    try:
        status = int(parts[1])
    except (IndexError, ValueError):
        status = 0
    headers: dict[str, str] = {}
    for ln in lines[1:]:
        if ":" not in ln:
            continue
        k, v = ln.split(":", 1)
        k = k.strip().lower()
        v = v.strip()
        if k in headers:
            headers[k] = headers[k] + ", " + v  # naive multi-value join
        else:
            headers[k] = v
    if "chunked" in headers.get("transfer-encoding", "").lower():
        rest = _dechunk(rest)
    return HttpResponse(status=status, headers=headers, body=rest)


# ── WebSocket ──────────────────────────────────────────────────────────────


class WsConnectionClosed(Exception):
    """Raised when the WS connection is no longer usable."""


class WsConnection:
    """Long-lived WS bridge to ``<server>/api/devices/bridge/ws``.

    Send/receive are wrapped behind ``send_text()`` and ``read_frames()``.
    Senders may come from any worker thread (a ``threading.Lock`` serialises
    socket writes); the reader is single-threaded (the daemon's main loop).
    """

    def __init__(self, server_url: str, cookie: str, expected_fingerprint: str = "",
                 cf_client_id: str = "", cf_client_secret: str = ""):
        self.server_url = server_url
        self.cookie = cookie
        self.expected_fingerprint = expected_fingerprint
        self.cf_client_id = cf_client_id
        self.cf_client_secret = cf_client_secret
        self._host, self._port, self._scheme, self._prefix = _split_url(server_url)
        self._sock: Optional[socket.socket] = None
        self._conn: Optional[WSConnection] = None
        self._send_lock = threading.Lock()
        self._closed = False

    # ----- lifecycle ---------------------------------------------------

    def connect(self) -> None:
        sock = socket.create_connection(
            (self._host, self._port), timeout=_DEFAULT_CONNECT_TIMEOUT
        )
        if self._scheme == "https":
            ctx = _make_ssl_context()
            sock = ctx.wrap_socket(sock, server_hostname=self._host)
            _verify_fingerprint(sock, self.expected_fingerprint)
        # Long-lived: no read timeout (the server-side ping every 30s
        # keeps the connection live; we send our own pings too).
        sock.settimeout(None)

        ws = WSConnection(ConnectionType.CLIENT)
        target = self._prefix + "/api/devices/bridge/ws"
        # wsproto's Request takes extra_headers as a list of (name, value).
        # The Cookie header carries our paired session.
        extra = [
            ("Origin", f"{self._scheme}://{self._host}"),
            ("User-Agent", "jc-client/0.1"),
        ]
        if self.cookie:
            extra.append(("Cookie", self.cookie))
        if self.cf_client_id and self.cf_client_secret:
            extra.append(("CF-Access-Client-Id", self.cf_client_id))
            extra.append(("CF-Access-Client-Secret", self.cf_client_secret))
        sock.sendall(
            ws.send(
                Request(
                    host=f"{self._host}:{self._port}",
                    target=target,
                    extra_headers=extra,
                )
            )
        )

        # Drain until we see AcceptConnection or RejectConnection.
        accepted = False
        deadline = time.time() + 10
        while time.time() < deadline:
            chunk = sock.recv(_RECV_CHUNK)
            if not chunk:
                raise WsConnectionClosed("server closed during handshake")
            ws.receive_data(chunk)
            for event in ws.events():
                if isinstance(event, AcceptConnection):
                    accepted = True
                    break
                if isinstance(event, RejectConnection):
                    raise WsConnectionClosed(
                        f"server rejected WS handshake: HTTP {event.status_code}"
                    )
            if accepted:
                break
        if not accepted:
            raise WsConnectionClosed("WS handshake timed out")

        self._sock = sock
        self._conn = ws

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._conn and self._sock:
            try:
                with self._send_lock:
                    self._sock.sendall(self._conn.send(CloseConnection(code=1000)))
            except Exception:
                pass
        try:
            if self._sock:
                self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass

    # ----- send --------------------------------------------------------

    def send_text(self, text: str) -> None:
        if self._closed or not self._conn or not self._sock:
            raise WsConnectionClosed("not connected")
        # Both the wsproto state mutation (_conn.send) AND the socket
        # write must happen inside the lock. wsproto isn't thread-safe;
        # without this, concurrent send_text calls from worker threads
        # interleave frame bytes and the server sees a malformed frame
        # then closes the connection.
        try:
            with self._send_lock:
                data = self._conn.send(TextMessage(data=text))
                self._sock.sendall(data)
        except (OSError, ssl.SSLError) as exc:
            self._closed = True
            raise WsConnectionClosed(str(exc)) from exc

    def send_ping(self, payload: bytes = b"") -> None:
        if self._closed or not self._conn or not self._sock:
            return
        try:
            with self._send_lock:
                self._sock.sendall(self._conn.send(Ping(payload=payload)))
        except (OSError, ssl.SSLError) as exc:
            self._closed = True
            raise WsConnectionClosed(str(exc)) from exc

    # ----- receive -----------------------------------------------------

    def read_frames(self) -> Iterator[dict]:
        """Yield parsed JSON messages (one per text frame) until the
        connection closes. Pings/pongs are handled inline and don't
        surface to the caller."""
        if not self._conn or not self._sock:
            return
        # wsproto delivers a large WS message as several TextMessage events
        # (one per recv chunk), with ``message_finished=True`` only on the last.
        # We must accumulate until the message is complete before parsing JSON —
        # otherwise any frame over one recv chunk (~8 KB) is silently lost. The
        # server's _pump does the same on its side; the relay sends large
        # mcp_frames in BOTH directions, so the client needs it too.
        text_buf = ""
        _MAX_FRAME_BYTES = 8 * 1024 * 1024
        while not self._closed:
            try:
                chunk = self._sock.recv(_RECV_CHUNK)
            except (ConnectionResetError, BrokenPipeError, OSError, ssl.SSLError):
                break
            if not chunk:
                break
            try:
                self._conn.receive_data(chunk)
            except Exception as exc:
                log.warning("ws protocol error: %s", exc)
                break
            for event in self._conn.events():
                if isinstance(event, TextMessage):
                    text_buf += event.data or ""
                    if not getattr(event, "message_finished", True):
                        continue
                    raw, text_buf = text_buf, ""
                    if len(raw) > _MAX_FRAME_BYTES:
                        log.warning("oversize frame (%d B) — dropping", len(raw))
                        continue
                    try:
                        yield json.loads(raw or "{}")
                    except Exception as exc:
                        log.warning("malformed json frame: %s", exc)
                elif isinstance(event, BytesMessage):
                    # Binary frames aren't part of the protocol; drop.
                    continue
                elif isinstance(event, Ping):
                    try:
                        with self._send_lock:
                            self._sock.sendall(
                                self._conn.send(Pong(payload=event.payload))
                            )
                    except Exception:
                        self._closed = True
                        return
                elif isinstance(event, Pong):
                    continue
                elif isinstance(event, CloseConnection):
                    self._closed = True
                    return
        self._closed = True
