"""The local link (unix_server.py): AF_UNIX on macOS, loopback + token on Windows.

The tcp tests run on any OS by forcing ``mode="tcp"``.
"""
import json
import os
import re
import shutil
import socket
import stat
import sys
import tempfile
import time

import pytest

from jc_client import unix_server
from jc_client.unix_server import UnixSocketServer, connect


class Echo(UnixSocketServer):
    thread_name = "echo"

    def _connection(self, conn):
        try:
            conn.settimeout(3)
            while True:
                data = conn.recv(65536)
                if not data:
                    return
                conn.sendall(data)
        except OSError:
            return
        finally:
            conn.close()


@pytest.fixture
def d():
    path = tempfile.mkdtemp(dir="/tmp" if sys.platform != "win32" else None, prefix="jli")
    yield path
    shutil.rmtree(path, ignore_errors=True)


def _endpoint(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _recv_all(s, n=3.0):
    s.settimeout(n)
    try:
        return s.recv(65536)
    except socket.timeout:
        return None


def test_tcp_roundtrip_after_auth(d):
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        s = connect(srv.path, 2.0)
        s.sendall(b"hi\n")
        assert _recv_all(s) == b"hi\n"
        s.close()
    finally:
        srv.close()


def test_tcp_wrong_token_closed(d):
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        ep = _endpoint(srv.path)
        s = socket.create_connection(("127.0.0.1", ep["port"]), timeout=2)
        s.sendall(b'{"auth":"bad"}\n')
        assert _recv_all(s) == b""
        s.close()
    finally:
        srv.close()


def test_tcp_no_auth_closed_after_timeout(d, monkeypatch):
    monkeypatch.setattr(unix_server, "AUTH_TIMEOUT", 0.2)
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        ep = _endpoint(srv.path)
        s = socket.create_connection(("127.0.0.1", ep["port"]), timeout=2)
        assert _recv_all(s, 2.0) == b""
        s.close()
    finally:
        srv.close()


def test_auth_and_payload_in_one_packet(d):
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        ep = _endpoint(srv.path)
        s = socket.create_connection(("127.0.0.1", ep["port"]), timeout=2)
        s.sendall(json.dumps({"auth": ep["token"]}).encode() + b"\nhi\n")
        assert _recv_all(s) == b"hi\n"
        s.close()
    finally:
        srv.close()


def test_endpoint_written_after_listen(d):
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        ep = _endpoint(srv.path)
        assert ep["v"] == 1 and ep["pid"] == os.getpid()
        s = socket.create_connection(("127.0.0.1", ep["port"]), timeout=1)
        s.close()
    finally:
        srv.close()


def test_endpoint_removed_on_close(d):
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    srv.close()
    assert not os.path.exists(srv.path)


def test_connect_stale_endpoint_fails_fast(d):
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    path = os.path.join(d, "ui.sock")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"v": 1, "port": port, "token": "0" * 64, "pid": 1}, fh)
    started = time.monotonic()
    with pytest.raises(ConnectionRefusedError):
        connect(path, 2.0)
    assert time.monotonic() - started < 1.0


def test_connect_missing_endpoint_refused(d):
    with pytest.raises(ConnectionRefusedError):
        connect(os.path.join(d, "nothing.sock"), 1.0)


@pytest.mark.skipif(sys.platform == "win32", reason="Unix sockets")
def test_unix_mode_unchanged(d):
    srv = Echo(os.path.join(d, "ui.sock"))
    srv.start()
    try:
        assert stat.S_ISSOCK(os.stat(srv.path).st_mode)
        assert stat.S_IMODE(os.stat(srv.path).st_mode) == 0o600
        s = connect(srv.path, 2.0)
        s.sendall(b"hi\n")
        assert _recv_all(s) == b"hi\n"
        s.close()
    finally:
        srv.close()


def test_token_is_64_hex(d):
    srv = Echo(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        assert re.fullmatch(r"[0-9a-f]{64}", _endpoint(srv.path)["token"])
    finally:
        srv.close()


@pytest.mark.skipif(sys.platform != "win32", reason="GetExtendedTcpTable")
def test_peer_pid_of_tcp_client_is_self(d):
    got = {}

    class Who(UnixSocketServer):
        def _connection(self, conn):
            got["pid"] = unix_server.peer_pid(conn)
            conn.close()

    srv = Who(os.path.join(d, "ui.sock"), mode="tcp")
    srv.start()
    try:
        s = connect(srv.path, 2.0)
        deadline = time.monotonic() + 2
        while "pid" not in got and time.monotonic() < deadline:
            time.sleep(0.02)
        s.close()
    finally:
        srv.close()
    assert got["pid"] == os.getpid()
