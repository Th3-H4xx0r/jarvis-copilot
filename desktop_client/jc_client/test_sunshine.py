"""Sunshine local-API client: paired clients, apps, pairing PIN — RED tests first."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from jc_client.sunshine import SunshineClient, SunshineUnavailable


class _Rec:
    def __init__(self):
        self.requests = []  # (method, path, headers, body)


def _make_handler(rec):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            rec.requests.append(("GET", self.path, dict(self.headers), None))
            if self.path == "/api/clients/list":
                if "Authorization" not in self.headers:
                    self._send({"status": False}, 401)
                    return
                self._send({"status": True, "named_certs": [
                    {"name": "Mac", "uuid": "u1"},
                    {"name": "TV", "uuid": "u2"},
                ]})
            elif self.path == "/api/csrf-token":
                self._send({"status": True, "token": "CSRF123"})
            elif self.path == "/api/apps":
                self._send({"status": True, "apps": [{"name": "Cyberpunk 2077"}]})
            elif self.path == "/api/config":
                self._send({"status": True, "sunshine_name": "GPC"})
            else:
                self._send({"status": False}, 404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode() if length else ""
            rec.requests.append(("POST", self.path, dict(self.headers), body))
            if self.headers.get("X-CSRF-Token") != "CSRF123":
                self._send({"status": False, "error": "csrf"}, 403)
                return
            self._send({"status": True})

    return H


@pytest.fixture
def server():
    rec = _Rec()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(rec))
    port = httpd.server_address[1]
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    try:
        yield port, rec
    finally:
        httpd.shutdown()


def _client(port):
    return SunshineClient("127.0.0.1", port, "admin", "pw", scheme="http")


def test_get_clients_parses_named_certs(server):
    port, rec = server
    clients = _client(port).get_clients()
    assert clients == [{"name": "Mac", "uuid": "u1"}, {"name": "TV", "uuid": "u2"}]
    get = [r for r in rec.requests if r[0] == "GET" and r[1] == "/api/clients/list"][0]
    assert get[2].get("Authorization", "").startswith("Basic ")


def test_state_change_fetches_csrf(server):
    port, rec = server
    ok = _client(port).submit_pin("1234")
    assert ok is True
    paths = [r[1] for r in rec.requests]
    assert "/api/csrf-token" in paths
    post = [r for r in rec.requests if r[0] == "POST" and r[1] == "/api/pin"][0]
    hdrs = {k.lower(): v for k, v in post[2].items()}
    assert hdrs.get("x-csrf-token") == "CSRF123"


def test_submit_pin_posts_pin(server):
    port, rec = server
    _client(port).submit_pin("4321")
    post = [r for r in rec.requests if r[0] == "POST" and r[1] == "/api/pin"][0]
    assert "4321" in post[3]


def test_unreachable_raises_SunshineUnavailable():
    c = SunshineClient("127.0.0.1", 1, "admin", "pw", scheme="http")
    assert c.reachable() is False
    with pytest.raises(SunshineUnavailable):
        c.get_clients()
