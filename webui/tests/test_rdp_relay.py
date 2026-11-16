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


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


@pytest.fixture()
def clock():
    return Clock()


@pytest.fixture()
def store(clock):
    s = RdpSessions(clock=clock, send_frame=lambda d, f: True, settings=lambda: {},
                    device_name=lambda d: "pranav-computer")
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
    assert store.get(sid).state == "reconnectable"      # a drop, not an end: the phone may come back


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


# ── reconnect after a brief drop (Review Focus 4) ───────────────────────────
def _drop(phone, t):
    phone.close()
    t.join(timeout=2)
    assert not t.is_alive()


def test_reopen_within_60s_is_accepted(store, echo, clock):
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, []))
    _drop(phone, t)
    clock.t += 59
    phone2, t2 = _start(store, sid, _connector(echo, []))      # same session, no new Face ID
    phone2.sendall(b"again")
    assert _read(phone2, 5) == b"again"
    assert store.get(sid).state == "connected"
    assert store.public(sid)["credential"]["ciphertext"] == IOS_CRED["ciphertext"]
    _drop(phone2, t2)


def test_reopen_after_60s_is_refused(store, echo, clock):
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, []))
    _drop(phone, t)
    clock.t += 61
    sess, err = rdp_relay.admit(sid, store)
    assert sess is None and err
    assert store.get(sid).state == "ended" and store.get(sid).reason == "dropped"
    assert store.get(sid).credential is None


def test_two_concurrent_relays_are_refused(store, echo, clock):
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, []))
    assert rdp_relay.admit(sid, store)[0] is None              # one live relay at a time
    _drop(phone, t)
    phone2, t2 = _start(store, sid, _connector(echo, []))
    assert rdp_relay.admit(sid, store)[0] is None
    _drop(phone2, t2)


def test_delete_then_reopen_is_refused(store, echo, clock):
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, []))
    store.end(sid, "disconnected")                             # DELETE /api/rdp/sessions/<id>
    t.join(timeout=2)
    assert store.get(sid).state == "ended"
    assert rdp_relay.admit(sid, store)[0] is None
    # and after a drop, Disconnect still ends it at once
    sid2 = _approved(store)
    p2, t2 = _start(store, sid2, _connector(echo, []))
    _drop(p2, t2)
    store.end(sid2, "disconnected")
    assert store.get(sid2).state == "ended" and rdp_relay.admit(sid2, store)[0] is None


def test_off_ends_a_reconnectable_session(store, echo, clock):
    sid = _approved(store)
    phone, t = _start(store, sid, _connector(echo, []))
    _drop(phone, t)
    store.on_off()
    assert store.get(sid).state == "cancelled" and rdp_relay.admit(sid, store)[0] is None
