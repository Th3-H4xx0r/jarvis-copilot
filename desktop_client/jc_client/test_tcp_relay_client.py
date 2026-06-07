"""Tests for the relay client's transport-agnostic byte bridge."""
import socket
import threading

from jc_client.tcp_relay_client import ByteIO, bridge


class ScriptIO(ByteIO):
    def __init__(self, chunks):
        self._chunks = list(chunks)
        self.written = []
        self.closed = False

    def read(self):
        return self._chunks.pop(0) if self._chunks else b""

    def write(self, data):
        self.written.append(data)

    def close(self):
        self.closed = True


def test_bridge_pumps_one_direction_and_closes():
    a = ScriptIO([b"hi", b"there"])
    b = ScriptIO([])
    bridge(a, b)
    assert b.written == [b"hi", b"there"]
    assert a.closed and b.closed


class SockIO(ByteIO):
    def __init__(self, sock):
        self._s = sock

    def read(self):
        try:
            return self._s.recv(65536)
        except OSError:
            return b""

    def write(self, data):
        self._s.sendall(data)

    def close(self):
        try:
            self._s.close()
        except OSError:
            pass


def test_wsclientio_close_emits_ws_close_frame():
    # Mirror of the server-side regression: the ProxyCommand must emit a real
    # WebSocket Close frame on teardown so the proxy chain EOFs the peer at once
    # (a bare TCP shutdown is held until the edge idle timeout). See tcp_relay.py.
    from wsproto import WSConnection, ConnectionType
    from wsproto.events import Request, AcceptConnection, CloseConnection
    from jc_client.tcp_relay_client import _WsClientIO

    client_ws = WSConnection(ConnectionType.CLIENT)
    server_ws = WSConnection(ConnectionType.SERVER)
    server_ws.receive_data(client_ws.send(Request(host="h", target="/r")))
    for ev in server_ws.events():
        if isinstance(ev, Request):
            client_ws.receive_data(server_ws.send(AcceptConnection()))
            break
    list(client_ws.events())  # drain AcceptConnection

    a, b = socket.socketpair()
    _WsClientIO(a, client_ws).close()

    b.settimeout(2.0)
    server_ws.receive_data(b.recv(4096))  # close frame sent before shutdown
    assert any(isinstance(ev, CloseConnection) for ev in server_ws.events())
    b.close()


def test_bridge_two_socketpairs_both_ways():
    a_in, a_out = socket.socketpair()
    b_in, b_out = socket.socketpair()
    t = threading.Thread(target=bridge, args=(SockIO(a_in), SockIO(b_in)),
                         daemon=True)
    t.start()
    a_out.sendall(b"ping")
    assert b_out.recv(4) == b"ping"   # a -> b
    b_out.sendall(b"pong")
    assert a_out.recv(4) == b"pong"   # b -> a
    a_out.close()
    t.join(timeout=2.0)
    assert not t.is_alive()
    b_out.close()
