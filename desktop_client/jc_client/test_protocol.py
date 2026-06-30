"""Tests for the bare-minimum HTTP response parser.

Regression coverage for the chunked-transfer-encoding bug: requests to the
tunnel-fronted webui (cloudflared -> nginx -> origin) come back with
``Transfer-Encoding: chunked`` for large bodies (e.g. a full session handoff).
The parser used to return the raw chunk-framed bytes verbatim, so ``.json()``
choked on the leading ``<hexsize>\\r\\n`` and silently returned ``{}`` — which
made ``recall_session_handoff`` look empty even though the server replied with
the data.
"""
import json
import socket as _socket

import pytest

from jc_client import protocol
from jc_client.protocol import WsConnection, WsConnectionClosed, _parse_http_response


def _resp(headers_lines: list[str], body: bytes) -> bytes:
    head = "\r\n".join(["HTTP/1.1 200 OK"] + headers_lines)
    return head.encode("ascii") + b"\r\n\r\n" + body


def test_content_length_body_is_returned_verbatim():
    payload = json.dumps({"entries": [1, 2, 3]}).encode("utf-8")
    raw = _resp([f"Content-Length: {len(payload)}",
                 "Content-Type: application/json"], payload)
    r = _parse_http_response(raw)
    assert r.status == 200
    assert r.json() == {"entries": [1, 2, 3]}


def test_connection_close_framing_still_works():
    payload = b'{"ok": true}'
    raw = _resp(["Content-Type: application/json", "Connection: close"], payload)
    r = _parse_http_response(raw)
    assert r.json() == {"ok": True}


def test_chunked_body_is_dechunked():
    """The core regression: a chunked JSON body must be reassembled."""
    doc = {"slug": "proj", "kind": "sessions",
           "entries": [{"id": "x", "content": "y" * 5000}]}
    payload = json.dumps(doc).encode("utf-8")
    # Split across two chunks + the terminating zero chunk.
    mid = len(payload) // 2
    c1, c2 = payload[:mid], payload[mid:]
    body = (
        f"{len(c1):x}\r\n".encode() + c1 + b"\r\n"
        + f"{len(c2):x}\r\n".encode() + c2 + b"\r\n"
        + b"0\r\n\r\n"
    )
    raw = _resp(["Content-Type: application/json; charset=utf-8",
                 "Transfer-Encoding: chunked"], body)
    r = _parse_http_response(raw)
    assert r.status == 200
    assert r.json() == doc
    assert r.json()["entries"][0]["content"] == "y" * 5000


def test_chunked_with_extension_and_trailer():
    """Chunk extensions (``size;ext``) and trailers must be tolerated."""
    payload = b'{"value": 42}'
    body = (
        f"{len(payload):x};name=value\r\n".encode() + payload + b"\r\n"
        + b"0\r\n"
        + b"X-Trailer: ignored\r\n\r\n"
    )
    raw = _resp(["Transfer-Encoding: chunked"], body)
    r = _parse_http_response(raw)
    assert r.json() == {"value": 42}


def test_chunked_case_insensitive_header():
    payload = b'{"a": 1}'
    body = f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n"
    raw = _resp(["transfer-encoding: CHUNKED"], body)
    r = _parse_http_response(raw)
    assert r.json() == {"a": 1}


# ── WS handshake must time out, never hang (stuck-"reconnecting" fix) ─────────


class _StalledSock:
    """TCP connects, but the peer never sends the WS upgrade response — recv()
    behaves like a real socket with a timeout: it raises ``socket.timeout``."""

    def __init__(self):
        self.timeouts = []

    def settimeout(self, t):
        self.timeouts.append(t)

    def sendall(self, data):
        pass

    def recv(self, n):
        raise _socket.timeout("timed out")

    def close(self):
        pass


def _accepting_sock():
    """A fake socket that completes a real WS handshake: it runs a server-side
    wsproto over the client's request bytes and returns a valid AcceptConnection."""
    from wsproto import ConnectionType, WSConnection as _WS
    from wsproto.events import AcceptConnection, Request

    server = _WS(ConnectionType.SERVER)

    class _S:
        def __init__(self):
            self.timeouts = []
            self._buf = b""

        def settimeout(self, t):
            self.timeouts.append(t)

        def sendall(self, data):
            server.receive_data(data)
            for ev in server.events():
                if isinstance(ev, Request):
                    self._buf += server.send(AcceptConnection())

        def recv(self, n):
            if self._buf:
                out, self._buf = self._buf, b""
                return out
            raise _socket.timeout("timed out")

        def close(self):
            pass

    return _S()


def test_ws_connect_raises_instead_of_hanging_on_silent_handshake(monkeypatch):
    sock = _StalledSock()
    monkeypatch.setattr(protocol.socket, "create_connection", lambda *a, **k: sock)
    ws = WsConnection("http://localhost:9", cookie="")
    with pytest.raises(WsConnectionClosed):
        ws.connect()
    # The recv loop was bounded by a finite socket timeout — never None — so it
    # could break out instead of blocking forever.
    assert all(t is not None for t in sock.timeouts)


def test_ws_connect_clears_timeout_after_successful_handshake(monkeypatch):
    sock = _accepting_sock()
    monkeypatch.setattr(protocol.socket, "create_connection", lambda *a, **k: sock)
    ws = WsConnection("http://localhost:9", cookie="")
    ws.connect()
    # Finite timeout DURING the handshake, then None for the long-lived phase —
    # otherwise the long-lived read would spuriously time out every few seconds.
    assert sock.timeouts[-1] is None
    assert any(t is not None for t in sock.timeouts[:-1])
