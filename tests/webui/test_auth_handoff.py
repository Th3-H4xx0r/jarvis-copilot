"""Tests for the /api/auth/handoff endpoint.

The desktop voice popup can't set the hermes_session cookie itself, so it
loads /api/auth/handoff?session=<value>&next=<path>; a live session value is
re-issued as a Set-Cookie and the response 302s to a sanitized same-origin
`next` path. Invalid sessions redirect to /login with no cookie.
"""
from __future__ import annotations

import http.client
import importlib
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))


class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers_sent = []
        self.ended = False
        self.request = object()
        self.headers = http.client.HTTPMessage()

    def send_response(self, code):
        self.status = code

    def send_header(self, k, v):
        self.headers_sent.append((k, v))

    def end_headers(self):
        self.ended = True

    def header(self, key):
        return next((v for k, v in self.headers_sent if k.lower() == key.lower()), None)


def _auth(monkeypatch):
    from api import auth
    importlib.reload(auth)
    monkeypatch.setattr(auth, "is_auth_enabled", lambda: True)
    return auth


def test_valid_session_sets_cookie_and_redirects(monkeypatch):
    auth = _auth(monkeypatch)
    monkeypatch.setattr(auth, "verify_session", lambda v: v == "GOODTOKEN")
    h = FakeHandler()
    auth.handle_auth_handoff(h, urlparse("/api/auth/handoff?session=GOODTOKEN&next=/?mini=voice"))
    assert h.status == 302
    assert h.header("Location") == "/?mini=voice"
    assert any(k == "Set-Cookie" and "hermes_session=GOODTOKEN" in v
               for k, v in h.headers_sent)
    assert h.ended


def test_invalid_session_redirects_to_login_no_cookie(monkeypatch):
    auth = _auth(monkeypatch)
    monkeypatch.setattr(auth, "verify_session", lambda v: False)
    h = FakeHandler()
    auth.handle_auth_handoff(h, urlparse("/api/auth/handoff?session=BAD&next=/?mini=voice"))
    assert h.status == 302
    assert h.header("Location") == "/login"
    # No real session cookie issued.
    assert not any(k == "Set-Cookie" and "hermes_session=" in v and "hermes_session=;" not in v
                   for k, v in h.headers_sent)


def test_next_open_redirect_is_sanitized(monkeypatch):
    auth = _auth(monkeypatch)
    monkeypatch.setattr(auth, "verify_session", lambda v: True)
    for bad in ["//evil.com", "https://evil.com", "evil", "", "/\\evil"]:
        h = FakeHandler()
        from urllib.parse import quote
        auth.handle_auth_handoff(
            h, urlparse(f"/api/auth/handoff?session=T&next={quote(bad, safe='')}"))
        assert h.header("Location") == "/?mini=voice", bad


def test_next_relative_path_is_preserved(monkeypatch):
    auth = _auth(monkeypatch)
    monkeypatch.setattr(auth, "verify_session", lambda v: True)
    h = FakeHandler()
    auth.handle_auth_handoff(h, urlparse("/api/auth/handoff?session=T&next=/voice"))
    assert h.header("Location") == "/voice"


def test_handoff_is_public_path(monkeypatch):
    auth = _auth(monkeypatch)
    assert "/api/auth/handoff" in auth.PUBLIC_PATHS
