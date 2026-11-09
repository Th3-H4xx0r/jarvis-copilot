"""The webui records security events and refuses requests from blocked IPs."""
import io
import json
from urllib.parse import urlparse

import pytest

from api import auth


class _Handler:
    def __init__(self, path="/", body=None, peer="127.0.0.1", headers=None, command="GET"):
        raw = json.dumps(body).encode() if body is not None else b""
        self.path = path
        self.command = command
        self.headers = {"Content-Length": str(len(raw)), **(headers or {})}
        self.rfile = io.BytesIO(raw)
        self.wfile = io.BytesIO()
        self.client_address = (peer, 50000)
        self.request = None
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, *_):
        pass

    def end_headers(self):
        pass


@pytest.fixture
def events(monkeypatch):
    seen = []
    import security.events as ev
    monkeypatch.setattr(ev, "emit", lambda source, kind, actor=None, **detail:
                        seen.append({"source": source, "kind": kind, "actor": actor or {}, **detail}))
    return seen


def _kinds(seen):
    return [e["kind"] for e in seen]


def test_unauthenticated_api_request_emits_auth_failed(events, monkeypatch):
    monkeypatch.setattr(auth, "is_auth_enabled", lambda: True)
    h = _Handler("/api/sessions", headers={"CF-Connecting-IP": "203.0.113.40",
                                           "User-Agent": "curl/8"})
    assert auth.check_auth(h, urlparse(h.path)) is False
    assert h.status == 401
    ev = [e for e in events if e["kind"] == "auth.failed"]
    assert len(ev) == 1
    assert ev[0]["reason"] == "no_cookie" and ev[0]["path"] == "/api/sessions"
    assert ev[0]["actor"]["ip"] == "203.0.113.40"


def test_forged_cookie_is_bad_cookie(events, monkeypatch):
    monkeypatch.setattr(auth, "is_auth_enabled", lambda: True)
    h = _Handler("/api/sessions", headers={"Cookie": f"{auth.COOKIE_NAME}=abc.def"})
    auth.check_auth(h, urlparse(h.path))
    assert [e["reason"] for e in events if e["kind"] == "auth.failed"] == ["bad_cookie"]


def test_valid_session_emits_session_seen_once_per_hour(events, monkeypatch):
    monkeypatch.setattr(auth, "is_auth_enabled", lambda: True)
    monkeypatch.setattr(auth, "_SESSION_SEEN", {})
    cookie = auth.create_session()
    for _ in range(3):
        h = _Handler("/api/sessions", headers={"Cookie": f"{auth.COOKIE_NAME}={cookie}",
                                               "CF-Connecting-IP": "198.51.100.41"})
        assert auth.check_auth(h, urlparse(h.path)) is True
    seen = [e for e in events if e["kind"] == "session.seen"]
    assert len(seen) == 1 and seen[0]["actor"]["ip"] == "198.51.100.41"


def test_bad_pair_code_emits_pair_failed_with_real_ip(events, tmp_path, monkeypatch):
    monkeypatch.setattr(auth, "_LOGIN_ATTEMPTS_FILE", tmp_path / ".login_attempts.json")
    monkeypatch.setattr(auth, "_login_attempts", {})
    import api.pairing as pairing
    monkeypatch.setattr(pairing, "claim_pairing_code", lambda *a, **k: None)
    from api.routes import handle_post
    h = _Handler("/api/auth/pair/claim", body={"code": "ZZZZZZ"}, command="POST",
                 headers={"CF-Connecting-IP": "203.0.113.42"})
    handle_post(h, urlparse(h.path))
    assert h.status == 401
    ev = [e for e in events if e["kind"] == "pair.failed"]
    assert len(ev) == 1 and ev[0]["actor"]["ip"] == "203.0.113.42"
    assert "ZZZZZZ" not in json.dumps(ev)


def test_blocked_ip_gets_403_before_any_route(events, tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security.blocklist import default_blocklist
    default_blocklist().block("203.0.113.43", "test", ttl_s=600)
    import server
    reached = []
    monkeypatch.setattr(server, "handle_get", lambda *a: reached.append(a) or True)
    monkeypatch.setattr(server, "check_auth", lambda *a: reached.append(a) or True)
    monkeypatch.setattr(server, "_BLOCK_LOGGED", {})
    for _ in range(2):
        h = server.Handler.__new__(server.Handler)
        h.__dict__.update(vars(_Handler("/api/sessions", headers={"CF-Connecting-IP": "203.0.113.43"})))
        h.send_response = lambda s, h=h: setattr(h, "status", s)
        h.send_header = lambda *a: None
        h.end_headers = lambda: None
        server.Handler.do_GET(h)
        assert h.status == 403
        assert json.loads(h.wfile.getvalue()) == {"error": "blocked"}
    assert reached == []
    assert _kinds(events).count("request.blocked") == 1   # once per IP per minute


def test_loopback_without_edge_header_is_never_blocked(events, tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security.blocklist import default_blocklist
    default_blocklist().block("127.0.0.1", "mistake", ttl_s=600)
    import server
    assert server._advisor_blocked(_Handler("/api/sessions")) is False


def test_revoke_device_emits_device_revoked(events, monkeypatch):
    import api.pairing as pairing
    store = {"devices": [{"id": "dev-1", "name": "Test Phone", "session_prefix": "abcd1234"}]}
    monkeypatch.setattr(pairing, "_read_devices", lambda: store)
    monkeypatch.setattr(pairing, "_write_devices", lambda d: None)
    assert pairing.revoke_device("dev-1") is True
    ev = [e for e in events if e["kind"] == "device.revoked"]
    assert len(ev) == 1 and ev[0]["actor"]["device_id"] == "dev-1"


def test_logout_emits_session_revoked(events):
    cookie = auth.create_session()
    auth.invalidate_session(cookie)
    assert "session.revoked" in _kinds(events)


def test_failed_login_emits_login_failed(events, tmp_path, monkeypatch):
    monkeypatch.setattr(auth, "_LOGIN_ATTEMPTS_FILE", tmp_path / ".login_attempts.json")
    monkeypatch.setattr(auth, "_login_attempts", {})
    monkeypatch.setattr(auth, "is_auth_enabled", lambda: True)
    monkeypatch.setattr(auth, "verify_password", lambda pw: False)
    from api.routes import handle_post
    h = _Handler("/api/auth/login", body={"password": "wrong-guess"}, command="POST",
                 headers={"CF-Connecting-IP": "203.0.113.44"})
    handle_post(h, urlparse(h.path))
    ev = [e for e in events if e["kind"] == "login.failed"]
    assert len(ev) == 1 and ev[0]["actor"]["ip"] == "203.0.113.44"
    assert "wrong-guess" not in json.dumps(ev)


def test_actor_for_never_raises():
    from security.netid import actor_for
    broken = type("H", (), {"client_address": None, "headers": None})()
    actor = actor_for(broken)
    assert actor["session_kind"] == "none" and actor["ip"] == ""
