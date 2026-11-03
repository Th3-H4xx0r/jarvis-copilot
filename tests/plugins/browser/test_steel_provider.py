"""Steel cloud browser plugin: create → CDP URL with the key + read-only and
interactive live views; release; registered like the other browser plugins.
No network: httpx.post is faked."""
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from plugins.browser.steel.provider import SteelBrowserProvider


class _Resp:
    def __init__(self, status, payload=None, text=""):
        self.status_code = status
        self._payload = payload
        self.text = text

    def json(self):
        return self._payload


@pytest.fixture
def steel(monkeypatch):
    monkeypatch.setenv("STEEL_API_KEY", "ste-test-key-123")
    monkeypatch.delenv("STEEL_BASE_URL", raising=False)
    sent = []

    def fake_post(url, headers=None, json=None, timeout=None):
        sent.append({"url": url, "headers": headers, "json": json})
        if url.endswith("/release"):
            return _Resp(200, {"success": True})
        return _Resp(200, {
            "id": "sess-42",
            "websocketUrl": "wss://connect.steel.dev?sessionId=sess-42",
            "debugUrl": "https://api.steel.dev/v1/sessions/sess-42/player",
            "sessionViewerUrl": "https://app.steel.dev/sessions/sess-42",
            "status": "live",
        })

    monkeypatch.setattr(httpx, "post", fake_post)
    return sent


def test_available_only_with_a_key(monkeypatch):
    monkeypatch.delenv("STEEL_API_KEY", raising=False)
    assert SteelBrowserProvider().is_available() is False
    monkeypatch.setenv("STEEL_API_KEY", "ste-x-12345678")
    assert SteelBrowserProvider().is_available() is True


def test_create_session_returns_cdp_and_live_views(steel):
    info = SteelBrowserProvider().create_session("chat1")
    req = steel[0]
    assert req["url"] == "https://api.steel.dev/v1/sessions"
    assert req["headers"]["Steel-Api-Key"] == "ste-test-key-123"
    assert req["json"]["timeout"] > 0
    assert info["bb_session_id"] == "sess-42"
    q = parse_qs(urlsplit(info["cdp_url"]).query)
    assert info["cdp_url"].startswith("wss://connect.steel.dev")
    assert q["apiKey"] == ["ste-test-key-123"] and q["sessionId"] == ["sess-42"]
    live = parse_qs(urlsplit(info["live_url"]).query)
    inter = parse_qs(urlsplit(info["live_interactive_url"]).query)
    assert live["interactive"] == ["false"] and inter["interactive"] == ["true"]
    assert info["live_url"].startswith("https://api.steel.dev/v1/sessions/sess-42/player")


def test_cdp_url_built_when_steel_sends_none(monkeypatch):
    monkeypatch.setenv("STEEL_API_KEY", "ste-k-12345678")
    url = SteelBrowserProvider().cdp_url_for({"id": "s1"})
    q = parse_qs(urlsplit(url).query)
    assert url.startswith("wss://connect.steel.dev") and q == {"apiKey": ["ste-k-12345678"], "sessionId": ["s1"]}


def test_create_failure_raises(monkeypatch):
    monkeypatch.setenv("STEEL_API_KEY", "ste-k-12345678")
    monkeypatch.setattr(httpx, "post", lambda *a, **k: _Resp(401, {}, "bad key"))
    with pytest.raises(RuntimeError, match="401"):
        SteelBrowserProvider().create_session("t")


def test_close_releases_the_session(steel):
    assert SteelBrowserProvider().close_session("sess-42") is True
    assert steel[-1]["url"] == "https://api.steel.dev/v1/sessions/sess-42/release"


def test_close_without_key_is_false_not_an_error(monkeypatch):
    monkeypatch.delenv("STEEL_API_KEY", raising=False)
    assert SteelBrowserProvider().close_session("x") is False
    SteelBrowserProvider().emergency_cleanup("x")   # never raises


def test_registered_as_a_browser_plugin():
    from jarviscopilot_cli.plugins import _ensure_plugins_discovered
    from agent.browser_registry import get_provider
    _ensure_plugins_discovered()
    provider = get_provider("steel")
    assert provider is not None and provider.display_name == "Steel"
    schema = provider.get_setup_schema()
    assert schema["env_vars"][0]["key"] == "STEEL_API_KEY"
