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


def test_ws_connect_reads_with_a_long_timeout_after_the_handshake(monkeypatch):
    sock = _accepting_sock()
    monkeypatch.setattr(protocol.socket, "create_connection", lambda *a, **k: sock)
    ws = WsConnection("http://localhost:9", cookie="")
    ws.connect()
    # Short timeouts DURING the handshake, then a long finite one for the link: never None, or a
    # half-dead link (live 2026-11-23, after the PC slept) blocks recv() forever and the PC drops off
    # Jarvis until someone restarts the client. The server text-pings every 40 s
    # (webui/api/device_bridge.py _ping_interval), so silence well past that means the link is dead.
    assert any(t is not None for t in sock.timeouts[:-1])
    assert sock.timeouts[-1] is not None and sock.timeouts[-1] >= 2 * _SERVER_PING_S
    assert sock.timeouts[-1] > protocol._HANDSHAKE_TIMEOUT


def test_the_ssh_relay_cannot_hang_on_a_silent_handshake(monkeypatch):
    """`jc-client tcp-relay` once dropped to no-timeout before its handshake: a tunnel that
    accepts TCP but never answers the upgrade blocked SSH forever."""
    from jc_client import credentials, tcp_relay_client

    sock = _StalledSock()
    monkeypatch.setattr(protocol.socket, "create_connection", lambda *a, **k: sock)
    monkeypatch.setattr(credentials, "load", lambda: credentials.Credentials(
        server_url="http://localhost:9", cookie="hermes_session=x", cert_fingerprint="ab"))
    with pytest.raises(WsConnectionClosed):
        tcp_relay_client._connect_relay()
    assert all(t is not None for t in sock.timeouts)


# ── a dead long-lived link must end the read loop, so the service reconnects ──────

_SERVER_PING_S = 40.0   # webui/api/device_bridge.py _ping_interval(): the server's text ping


def _linked_ws(wrap=lambda s: s):
    """A WsConnection already past its handshake, over a real socketpair: (ws, our end, the server's end)."""
    from wsproto import ConnectionType, WSConnection as _WS
    from wsproto.events import AcceptConnection, Request

    ours, theirs = _socket.socketpair()
    client, server = _WS(ConnectionType.CLIENT), _WS(ConnectionType.SERVER)
    server.receive_data(client.send(Request(host="localhost", target="/api/devices/bridge/ws")))
    assert any(isinstance(e, Request) for e in server.events())
    client.receive_data(server.send(AcceptConnection()))
    assert any(isinstance(e, AcceptConnection) for e in client.events())
    ws = WsConnection("http://localhost:9", cookie="")
    ws._sock, ws._conn = wrap(ours), client
    return ws, ours, theirs


def test_a_read_timeout_ends_the_link_and_close_frees_the_socket():
    ws, ours, theirs = _linked_ws()
    ours.settimeout(0.2)              # the server went quiet: a half-dead link
    assert list(ws.read_frames()) == []
    ws.close()                        # the service's finally: must free the socket even though the link is already marked closed
    assert ours.fileno() == -1


class _FailingSend:
    """Our real socket, but writes fail: the link died under a send."""

    def __init__(self, sock):
        self._s = sock

    def sendall(self, data):
        raise OSError("connection reset")

    def __getattr__(self, name):
        return getattr(self._s, name)


@pytest.mark.parametrize("send", ["text", "ping"])
def test_a_failed_send_wakes_the_reader_blocked_in_recv(send):
    import threading
    import time

    ws, ours, theirs = _linked_ws(_FailingSend)
    done = threading.Event()

    def reader():
        list(ws.read_frames())
        done.set()
    threading.Thread(target=reader, daemon=True).start()
    time.sleep(0.1)                   # the reader is blocked in recv()
    with pytest.raises(WsConnectionClosed):
        ws.send_text("{}") if send == "text" else ws.send_ping(b"jc")
    assert done.wait(2), "the reader stayed blocked, so the reconnect loop never ran"
    assert theirs.fileno() != -1      # (the server's end stayed open: only our shutdown could wake it)
