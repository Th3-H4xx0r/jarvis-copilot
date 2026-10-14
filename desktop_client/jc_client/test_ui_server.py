"""ui.sock — how the Jarvis Mac app hears jc-client: hello, then pushed state;
requests (decide, session, hooks…) answered on the same connection."""
import json
import os
import shutil
import socket
import stat
import tempfile
import time

import pytest

from jc_client.ui_server import UiServer


@pytest.fixture
def sockdir():
    d = tempfile.mkdtemp(dir="/tmp", prefix="jui")
    yield d
    shutil.rmtree(d, ignore_errors=True)


class Client:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(3)
        self.s.connect(path)
        self.buf = b""

    def send(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())

    def recv(self):
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def close(self):
        self.s.close()


def make(sockdir, on_request=None):
    srv = UiServer(os.path.join(sockdir, "ui.sock"),
                   hello=lambda: {"api": "http://127.0.0.1:5555", "approvals": True},
                   on_request=on_request or (lambda req: {"ok": True, "echo": req.get("type")}))
    srv.start()
    return srv


def test_hello_comes_first(sockdir):
    srv = make(sockdir)
    try:
        c = Client(srv.path)
        assert c.recv() == {"type": "hello", "api": "http://127.0.0.1:5555", "approvals": True}
        c.close()
    finally:
        srv.close()


def test_socket_is_owner_only(sockdir):
    srv = make(sockdir)
    try:
        assert stat.S_IMODE(os.stat(srv.path).st_mode) == 0o600
    finally:
        srv.close()


def test_broadcast_reaches_every_client(sockdir):
    srv = make(sockdir)
    try:
        a, b = Client(srv.path), Client(srv.path)
        a.recv(), b.recv()
        end = time.time() + 2
        while srv.client_count() < 2 and time.time() < end:
            time.sleep(0.01)
        srv.broadcast({"type": "sessions", "sessions": [{"key": "k"}]})
        assert a.recv()["sessions"] == [{"key": "k"}]
        assert b.recv()["sessions"] == [{"key": "k"}]
    finally:
        srv.close()


def test_request_gets_a_reply_with_its_id(sockdir):
    srv = make(sockdir)
    try:
        c = Client(srv.path)
        c.recv()
        c.send({"type": "decide", "id": 7, "fingerprint": "f", "decision": "allow"})
        reply = c.recv()
        assert reply == {"type": "reply", "id": 7, "ok": True, "echo": "decide"}
    finally:
        srv.close()


def test_a_failing_handler_answers_an_error(sockdir):
    def boom(req):
        raise RuntimeError("nope")
    srv = make(sockdir, on_request=boom)
    try:
        c = Client(srv.path)
        c.recv()
        c.send({"type": "session", "id": 1})
        reply = c.recv()
        assert reply["type"] == "reply" and reply["id"] == 1 and reply["ok"] is False
    finally:
        srv.close()


def test_a_dead_client_is_dropped(sockdir):
    srv = make(sockdir)
    try:
        c = Client(srv.path)
        c.recv()
        c.close()
        time.sleep(0.05)
        srv.broadcast({"type": "x"})
        srv.broadcast({"type": "x"})
        end = time.time() + 2
        while srv.client_count() and time.time() < end:
            time.sleep(0.01)
        assert srv.client_count() == 0
    finally:
        srv.close()


def test_garbage_lines_are_ignored(sockdir):
    srv = make(sockdir)
    try:
        c = Client(srv.path)
        c.recv()
        c.s.sendall(b"not json\n")
        c.send({"type": "hooks", "id": 2})
        assert c.recv()["id"] == 2
    finally:
        srv.close()
