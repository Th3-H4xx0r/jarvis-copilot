"""Unit tests for the WS<->TCP relay byte-pump core (no real WebSocket)."""
import socket
import threading

from api.tcp_relay import Channel, SocketChannel, relay_pump


class ScriptChannel(Channel):
    """Yields a fixed list of byte chunks from recv(), then EOF; records sends."""

    def __init__(self, to_recv):
        self._recv = list(to_recv)
        self.sent = []
        self.closed = False

    def recv(self):
        if self._recv:
            return self._recv.pop(0)
        return None  # EOF after the scripted data

    def send(self, data):
        self.sent.append(data)

    def close(self):
        self.closed = True


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def test_relay_pump_bridges_two_socketpairs_both_ways():
    # Real, deterministic bidirectional test: bytes written on either outer end
    # appear on the other, proving the pump relays both directions live.
    a_in, a_out = socket.socketpair()
    b_in, b_out = socket.socketpair()
    t = threading.Thread(target=relay_pump,
                         args=(SocketChannel(a_in), SocketChannel(b_in)),
                         daemon=True)
    t.start()
    a_out.sendall(b"ping")
    assert _recv_exact(b_out, 4) == b"ping"
    b_out.sendall(b"pong")
    assert _recv_exact(a_out, 4) == b"pong"
    # Closing one outer end tears the whole relay down.
    a_out.close()
    t.join(timeout=2.0)
    assert not t.is_alive()
    b_out.close()


def test_relay_pump_close_propagates():
    # One side closes immediately (no data); the relay must terminate cleanly.
    a = ScriptChannel([])
    b = ScriptChannel([b"x"])
    relay_pump(a, b)
    assert a.closed and b.closed
    # b's single chunk may or may not have flushed before teardown, but a got
    # nothing and the pump returned (no hang) — that's the contract.


def test_socketchannel_loopback_echo():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    def _echo():
        conn, _ = srv.accept()
        while True:
            d = conn.recv(4096)
            if not d:
                break
            conn.sendall(d)
        conn.close()

    threading.Thread(target=_echo, daemon=True).start()
    client = socket.create_connection(("127.0.0.1", port), timeout=2)
    ch = SocketChannel(client)
    ch.send(b"ping")
    assert ch.recv() == b"ping"
    ch.close()
    srv.close()


def test_socketchannel_recv_none_after_close():
    a, b = socket.socketpair()
    ch = SocketChannel(a)
    b.close()
    # peer closed -> recv returns b"" (falsy) which the pump treats as EOF
    assert not ch.recv()
    ch.close()


def test_wssocketchannel_close_emits_ws_close_frame():
    # Regression: teardown MUST send a real WebSocket Close frame, not just a
    # raw TCP shutdown. WS-aware proxies (cloudflared/nginx/CF) forward a Close
    # frame to the peer immediately but sit on a bare half-close until their
    # idle timeout — which hung every short-lived SSH/scp the sync engine runs
    # ~125 s at teardown and timed out Mutagen's agent-copy.
    from wsproto import WSConnection, ConnectionType
    from wsproto.events import Request, AcceptConnection, CloseConnection
    from api.tcp_relay import WsSocketChannel

    server_ws = WSConnection(ConnectionType.SERVER)
    client_ws = WSConnection(ConnectionType.CLIENT)
    # Drive the handshake so both wsproto state machines reach OPEN.
    server_ws.receive_data(
        client_ws.send(Request(host="h", target="/api/devices/tcp-relay")))
    for ev in server_ws.events():
        if isinstance(ev, Request):
            client_ws.receive_data(server_ws.send(AcceptConnection()))
            break
    list(client_ws.events())  # drain AcceptConnection

    a, b = socket.socketpair()
    WsSocketChannel(a, server_ws).close()

    b.settimeout(2.0)
    client_ws.receive_data(b.recv(4096))  # close frame was sent before shutdown
    assert any(isinstance(ev, CloseConnection) for ev in client_ws.events())
    b.close()


def test_wssocketchannel_send_keepalive_is_text_and_ignored_inbound():
    # The keepalive MUST be a TEXT frame (in-band data that flushes the proxy's
    # held last-frame) and MUST NOT be mistaken for SSH stream bytes on recv.
    from wsproto import WSConnection, ConnectionType
    from wsproto.events import Request, AcceptConnection, TextMessage, BytesMessage
    from api.tcp_relay import WsSocketChannel

    server_ws = WSConnection(ConnectionType.SERVER)
    client_ws = WSConnection(ConnectionType.CLIENT)
    server_ws.receive_data(
        client_ws.send(Request(host="h", target="/api/devices/tcp-relay")))
    for ev in server_ws.events():
        if isinstance(ev, Request):
            client_ws.receive_data(server_ws.send(AcceptConnection()))
            break
    list(client_ws.events())

    a, b = socket.socketpair()
    ch = WsSocketChannel(a, server_ws)
    ch.send_keepalive()
    # Peer sees a TEXT frame (not binary) — so it's data-plane (resets idle) but
    # the relay drops it rather than writing it to the SSH socket.
    b.settimeout(2.0)
    client_ws.receive_data(b.recv(4096))
    evs = list(client_ws.events())
    assert any(isinstance(e, TextMessage) for e in evs)
    assert not any(isinstance(e, BytesMessage) for e in evs)
    ch.close()
    b.close()


def test_is_loopback_enforcement():
    from api.tcp_relay import _is_loopback
    assert _is_loopback("127.0.0.1")
    assert _is_loopback("localhost")
    assert _is_loopback("::1")
    assert not _is_loopback("8.8.8.8")
    assert not _is_loopback("169.254.169.254")  # cloud metadata SSRF target
    assert not _is_loopback("nonexistent.invalid.")
