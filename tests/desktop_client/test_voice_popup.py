"""Tests for the desktop voice-orb popup + its localhost pinned reverse proxy."""
from __future__ import annotations

import http.client
import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def _vp():
    from jc_client import voice_popup
    importlib.reload(voice_popup)
    return voice_popup


class _PairedCreds:
    server_url = "https://hermes:8787"
    cookie = "SESSIONVAL"
    cert_fingerprint = "AABBCC"

    @property
    def paired(self):
        return True


class _UnpairedCreds:
    server_url = ""
    cookie = ""
    cert_fingerprint = ""

    @property
    def paired(self):
        return False


# ── build_upstream_head ──────────────────────────────────────────────────

def test_build_upstream_head_injects_cookie_and_rewrites_host():
    vp = _vp()
    h = http.client.HTTPMessage()
    h.add_header("User-Agent", "x")
    h.add_header("Cookie", "hermes_session=ORIGINAL")  # must be replaced
    h.add_header("Host", "evil.example")               # must be dropped
    out = vp.build_upstream_head("GET", "/?mini=voice", h, "SECRET", "hermes", 8787, False).decode()
    assert out.startswith("GET /?mini=voice HTTP/1.1\r\n")
    assert "Host: hermes:8787" in out
    assert "Cookie: hermes_session=SECRET" in out
    assert "hermes_session=ORIGINAL" not in out
    assert "Host: evil.example" not in out
    assert "User-Agent: x" in out
    assert "Connection: close" in out
    assert out.endswith("\r\n\r\n")


def test_build_upstream_head_does_not_double_cookie_prefix():
    # creds.cookie is the full "hermes_session=<value>" string — must be sent
    # as-is, never "hermes_session=hermes_session=<value>" (which 302s to /pair).
    vp = _vp()
    h = http.client.HTTPMessage()
    out = vp.build_upstream_head(
        "GET", "/?mini=voice", h, "hermes_session=abc.def", "hermes", 8787, False).decode()
    assert "Cookie: hermes_session=abc.def" in out
    assert "hermes_session=hermes_session=" not in out


def test_build_upstream_head_preserves_websocket_upgrade():
    vp = _vp()
    h = http.client.HTTPMessage()
    h.add_header("Upgrade", "websocket")
    h.add_header("Connection", "Upgrade")
    h.add_header("Sec-WebSocket-Key", "KEY==")
    out = vp.build_upstream_head("GET", "/api/voice/s2s/ws", h, "S", "hermes", 8787, True).decode()
    assert "Upgrade: websocket" in out
    assert "Connection: Upgrade" in out
    assert "Sec-WebSocket-Key: KEY==" in out
    assert "Connection: close" not in out


# ── PinnedProxy config (same source as the tray) ───────────────────────────

def test_pinned_proxy_uses_configured_server_details():
    vp = _vp()
    p = vp.PinnedProxy("https://hermes:8787", "FINGER", "COOKIE")
    assert p.host == "hermes" and p.port == 8787 and p.scheme == "https"
    assert p.fingerprint == "FINGER" and p.cookie == "COOKIE"


# ── run_voice_popup ────────────────────────────────────────────────────────

class _FakeProxy:
    instances = []

    def __init__(self, server_url, fingerprint, cookie):
        self.args = (server_url, fingerprint, cookie)
        self.waited = False
        self.shut = False
        _FakeProxy.instances.append(self)

    def start(self):
        return 54321

    def wait(self):
        self.waited = True

    def shutdown(self):
        self.shut = True


def test_run_voice_popup_loads_local_proxy_url_in_webview(monkeypatch):
    vp = _vp()
    _FakeProxy.instances = []
    monkeypatch.setattr(vp.credentials, "load", lambda: _PairedCreds())
    monkeypatch.setattr(vp, "PinnedProxy", _FakeProxy)

    calls = {}

    class FakeWebview:
        def create_window(self, title, url, **kw):
            calls["title"] = title
            calls["url"] = url
            calls["kw"] = kw

        def start(self, **kw):
            calls["started"] = True

    monkeypatch.setattr(vp, "_import_webview", lambda: FakeWebview())
    vp.run_voice_popup()

    assert calls["url"] == "http://127.0.0.1:54321/?mini=voice"
    assert calls["kw"].get("frameless") is True
    assert calls["kw"].get("on_top") is True
    assert calls.get("started") is True
    # Proxy built from the configured (tray) credentials and torn down after.
    assert _FakeProxy.instances[0].args == ("https://hermes:8787", "AABBCC", "SESSIONVAL")
    assert _FakeProxy.instances[0].shut is True


def test_run_voice_popup_browser_fallback_serves_local_proxy(monkeypatch):
    vp = _vp()
    _FakeProxy.instances = []
    monkeypatch.setattr(vp.credentials, "load", lambda: _PairedCreds())
    monkeypatch.setattr(vp, "PinnedProxy", _FakeProxy)
    monkeypatch.setattr(vp, "_import_webview", lambda: None)
    opened = {}
    monkeypatch.setattr(vp.webbrowser, "open", lambda u: opened.setdefault("url", u))
    vp.run_voice_popup()
    assert opened["url"] == "http://127.0.0.1:54321/?mini=voice"
    assert _FakeProxy.instances[0].waited is True
    assert _FakeProxy.instances[0].shut is True


def test_run_voice_popup_noop_when_unpaired(monkeypatch):
    vp = _vp()
    monkeypatch.setattr(vp.credentials, "load", lambda: _UnpairedCreds())

    def _boom(*_a, **_k):
        raise AssertionError("must not start a proxy when unpaired")

    monkeypatch.setattr(vp, "PinnedProxy", _boom)
    monkeypatch.setattr(vp, "_import_webview", _boom)
    vp.run_voice_popup()  # returns cleanly, nothing launched
