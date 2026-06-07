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
