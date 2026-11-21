"""Sunshine local-API client: paired clients, apps, pairing PIN — RED tests first."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from jc_client.sunshine import SunshineClient, SunshineUnavailable


PID = "13270f21e5f70861ecdfd7ae0a10ff4f"


class _Rec:
    def __init__(self):
        self.requests = []  # (method, path, headers, body)
        self.csrf_value = "CSRF123"   # what GET /api/csrf-token hands out


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
                # Real Sunshine: {"csrf_token": "..."} (key csrf_token, not token).
                self._send({"csrf_token": rec.csrf_value})
            elif self.path == "/api/pin":
                # Real Sunshine: the pending pair requests a Moonlight client started.
                self._send({"pairings": [
                    {"id": PID, "name": "roth", "address": "192.168.1.69"},
                ]})
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
                self._send({"status": False, "error": "Invalid CSRF token"}, 400)
                return
            if self.path == "/api/pin":
                data = json.loads(body or "{}")
                pid = str(data.get("pairing_id") or "")
                if len(pid) != 32 or any(c not in "0123456789abcdef" for c in pid.lower()):
                    self._send({"error": "pairing_id must contain exactly 32 hexadecimal characters"}, 400)
                    return
                # Real Sunshine answers 200 either way; status false = wrong PIN / unknown id.
                self._send({"status": pid == PID and data.get("pin") == "1234"})
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
    ok = _client(port).submit_pin("1234", "roth", PID)
    assert ok is True
    paths = [r[1] for r in rec.requests]
    assert "/api/csrf-token" in paths
    post = [r for r in rec.requests if r[0] == "POST" and r[1] == "/api/pin"][0]
    hdrs = {k.lower(): v for k, v in post[2].items()}
    assert hdrs.get("x-csrf-token") == "CSRF123"


def test_submit_pin_posts_pin(server):
    port, rec = server
    _client(port).submit_pin("4321", "roth", PID)
    post = [r for r in rec.requests if r[0] == "POST" and r[1] == "/api/pin"][0]
    assert "4321" in post[3]


def test_unreachable_raises_SunshineUnavailable():
    c = SunshineClient("127.0.0.1", 1, "admin", "pw", scheme="http")
    assert c.reachable() is False
    with pytest.raises(SunshineUnavailable):
        c.get_clients()


# ── probe (detect) ────────────────────────────────────────────────────────
def test_probe_running_and_logged_in(server):
    port, rec = server
    assert _client(port).probe() == {"running": True, "needs_login": False}


def test_probe_running_but_needs_login(monkeypatch):
    from jc_client.sunshine import SunshineAuthError
    c = SunshineClient("127.0.0.1", 1, "admin", "pw", scheme="http")

    def boom(path):
        raise SunshineAuthError("auth failed (401)")

    monkeypatch.setattr(c, "_get", boom)
    assert c.probe() == {"running": True, "needs_login": True}


def test_probe_not_running(monkeypatch):
    c = SunshineClient("127.0.0.1", 1, "admin", "pw", scheme="http")

    def boom(path):
        raise SunshineUnavailable("connection refused")

    monkeypatch.setattr(c, "_get", boom)
    assert c.probe() == {"running": False, "needs_login": False}


def test_auth_error_is_a_sunshine_unavailable_subclass():
    from jc_client.sunshine import SunshineAuthError
    assert issubclass(SunshineAuthError, SunshineUnavailable)



# ── the real Sunshine pairing API (verified live 2026-11-21) ──────────────
def test_csrf_reads_the_csrf_token_key(server):
    port, rec = server
    assert _client(port)._csrf() == "CSRF123"


def test_pending_pairings_parses_pairings_list(server):
    port, rec = server
    assert _client(port).pending_pairings() == [
        {"id": PID, "name": "roth", "address": "192.168.1.69"}]
    get = [r for r in rec.requests if r[0] == "GET" and r[1] == "/api/pin"][0]
    assert get[2].get("Authorization", "").startswith("Basic ")


def test_submit_pin_sends_pairing_id_pin_and_name(server):
    port, rec = server
    assert _client(port).submit_pin("1234", "roth", PID) is True
    post = [r for r in rec.requests if r[0] == "POST" and r[1] == "/api/pin"][0]
    assert json.loads(post[3]) == {"pairing_id": PID, "pin": "1234", "name": "roth"}


def test_submit_pin_wrong_pin_returns_false(server):
    port, rec = server
    assert _client(port).submit_pin("9999", "roth", PID) is False


def test_submit_pin_bad_pairing_id_raises_with_sunshine_message(server):
    from jc_client.sunshine import SunshineError
    port, rec = server
    with pytest.raises(SunshineError) as e:
        _client(port).submit_pin("1234", "roth", "")
    assert "pairing_id" in str(e.value)
    assert e.value.status == 400


def test_csrf_rejection_raises_its_own_error(server):
    from jc_client.sunshine import SunshineCsrfError
    port, rec = server
    rec.csrf_value = "stale"
    with pytest.raises(SunshineCsrfError) as e:
        _client(port).submit_pin("1234", "roth", PID)
    assert "CSRF" in str(e.value)


def test_request_errors_are_not_unavailable():
    # A 400 means Sunshine answered: never read it as "Sunshine is down".
    from jc_client.sunshine import SunshineCsrfError, SunshineError
    assert not issubclass(SunshineError, SunshineUnavailable)
    assert issubclass(SunshineCsrfError, SunshineError)
