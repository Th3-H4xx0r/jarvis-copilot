"""The iPhone's Remote Desktop relay (plan 2026-11-15-remote-desktop, Task 3): a WebSocket carried
byte-for-byte to the PC's RDP port. Only an approved iPhone session opens it, once; the target is
the session's PC on 3389, never something the client picks; switching the integration off closes
it within 2 s."""
from __future__ import annotations

import socket
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api import rdp_relay  # noqa: E402
from api.rdp_sessions import RdpSessions  # noqa: E402
from api.tcp_relay import SocketChannel  # noqa: E402

READY = {"edition": "Windows 11 Pro", "rdp_enabled": True, "firewall_scoped": True, "username": "u",
         "tailscale_ip": "100.119.223.124", "idle_s": 900.0, "locked": True, "game": None,
         "remote_session": False, "has_password": True}
IOS_CRED = {"ciphertext": "Y3Q=", "ephemeral_pub": "ZXA=", "nonce": "bm8="}


@pytest.fixture()
def echo():
    """A loopback 'PC': echoes every byte back."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    stop = threading.Event()

    def serve():
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=_echo, args=(conn,), daemon=True).start()

    def _echo(conn):
        while True:
            try:
                d = conn.recv(4096)
            except OSError:
                break
            if not d:
                break
            conn.sendall(d)
        conn.close()

    threading.Thread(target=serve, daemon=True).start()
    yield srv.getsockname()
    stop.set()
    srv.close()


@pytest.fixture()
def store():
    s = RdpSessions(send_frame=lambda d, f: True, settings=lambda: {}, device_name=lambda d: "pranav-computer")
    s.put_status("pc-1", dict(READY))
    return s


def _approved(store, client="ios"):
    sid = store.create("pc-1", client, True, "KEY" if client == "ios" else None)["session"]["id"]
    store.on_credential("pc-1", {"session_id": sid, "ok": True,
                                 "credential": IOS_CRED if client == "ios" else {"password": "pw"}})
    return sid


def _connector(echo, seen):
    def connect(addr, timeout=None):
        seen.append(addr)
        return socket.create_connection(echo, timeout=timeout)
    return connect


def _start(store, sid, connect):
    """Run the relay in a thread with an in-memory 'WebSocket' (a socketpair); returns the phone's end."""
    phone, ws_side = socket.socketpair()
    sess, err = rdp_relay.admit(sid, store)
    assert sess is not None, err
    t = threading.Thread(target=rdp_relay.run, args=(sess, SocketChannel(ws_side), store, connect), daemon=True)
    t.start()
    return phone, t


def _read(sock, n, timeout=2.0):
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def test_relay_requires_approved_ios_session(store):
    approving = store.create("pc-1", "ios", True, "KEY")["session"]["id"]
    assert rdp_relay.admit(approving, store)[0] is None
    web = _approved(store, "web")
    assert rdp_relay.admit(web, store)[0] is None
    assert rdp_relay.admit("does-not-exist", store)[0] is None
    assert rdp_relay.admit(_approved(store), store)[0] is not None


def test_relay_single_use(store):
    sid = _approved(store)
    first, _ = rdp_relay.admit(sid, store)
    assert first is not None and store.get(sid).state == "connected"
    second, err = rdp_relay.admit(sid, store)
    assert second is None and err


def test_relay_pumps_bytes_both_ways(store, echo):
    seen = []
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, seen))
    phone.sendall(b"\x03\x00\x00\x13hello-rdp")         # an RDP-ish first packet
    assert _read(phone, 13) == b"\x03\x00\x00\x13hello-rdp"
    phone.close()
    t.join(timeout=2)
    assert not t.is_alive()
    assert store.get(sid).state == "ended"


def test_off_closes_live_relays(store, echo):
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, []))
    phone.sendall(b"x")
    assert _read(phone, 1) == b"x"
    started = time.monotonic()
    store.on_off()
    t.join(timeout=2)
    assert not t.is_alive() and time.monotonic() - started < 2.0
    assert _read(phone, 1, timeout=1) == b""            # the phone sees the close
    assert store.get(sid).state == "cancelled"


def test_relay_target_is_fixed(store, echo):
    seen = []
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, seen))
    phone.close()
    t.join(timeout=2)
    assert seen == [("100.119.223.124", 3389)]          # the session's PC, RDP port only


def test_path_parsing():
    assert rdp_relay.session_id_of("/api/rdp/relay/AbC_-123456789") == "AbC_-123456789"
    assert rdp_relay.session_id_of("/api/rdp/relay/") is None
    assert rdp_relay.session_id_of("/api/rdp/relay/../etc") is None
    assert rdp_relay.session_id_of("/api/other") is None
