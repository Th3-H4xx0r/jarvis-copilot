"""The chat's live browser card over HTTP — Contract A (2026-11-03).

GET  /api/browser/sessions/<id>            the card's session
POST /api/browser/sessions/<id>/move       "Run on cloud browser"
POST /api/browser/sessions/<id>/takeover   Take over / Hand back to Jarvis
GET  /api/browser/replays/<id>.mp4         the replay, Range-aware
"""
import io
import json
from urllib.parse import urlparse

import pytest

from api import browser_routes
from api import config as api_config

CONTRACT_KEYS = {
    "id", "engine", "provider", "provider_name", "status", "url", "title", "live_url",
    "live_interactive_url", "takeover", "move_requested", "replay_url", "replay_status",
    "can_move_to_cloud", "cloud_ready", "cloud_hint", "updated_at",
}


class _Handler:
    def __init__(self, headers=None):
        self.wfile = io.BytesIO()
        self.headers = headers or {}
        self.status = None
        self.sent = {}

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        self.sent[key] = value

    def end_headers(self):
        pass

    def payload(self):
        return json.loads(self.wfile.getvalue().decode("utf-8"))


@pytest.fixture
def store(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("STEEL_API_KEY", raising=False)
    from tools import browser_sessions
    monkeypatch.setattr(browser_sessions, "_browser_config", lambda: {})
    return browser_sessions


def _cloud_ready(monkeypatch, store):
    class P:
        name, display_name = "steel", "Steel"
    monkeypatch.setattr(store, "live_provider", lambda: P())
    monkeypatch.setattr(store, "live_provider_name", lambda: "steel")


def _on_cloud(store, sid):
    store.update(sid, engine="cloud", provider="steel", provider_name="Steel",
                 live_url="https://api.steel.dev/v1/sessions/s/player?interactive=false&showControls=false",
                 live_interactive_url="https://api.steel.dev/v1/sessions/s/player?interactive=true&showControls=true")


def test_get_returns_contract_a(store):
    sid = store.ensure("chat1")
    store.update(sid, url="https://www.example.com/flights", title="Flights")
    status, body = browser_routes.handle_browser_request("GET", f"sessions/{sid}", None)
    assert status == 200 and CONTRACT_KEYS <= set(body)
    assert body["id"] == sid and body["engine"] == "lightpanda" and body["provider"] is None
    assert body["live_url"] is None and body["can_move_to_cloud"] is True
    assert body["cloud_ready"] is False and body["cloud_hint"] == "Add a Steel key in Settings → Providers"


def test_cloud_session_shows_its_live_views(store, monkeypatch):
    _cloud_ready(monkeypatch, store)
    sid = store.ensure("chat1")
    _on_cloud(store, sid)
    _, body = browser_routes.handle_browser_request("GET", f"sessions/{sid}", None)
    assert body["engine"] == "cloud" and body["provider"] == "steel" and body["provider_name"] == "Steel"
    assert "interactive=false" in body["live_url"] and "interactive=true" in body["live_interactive_url"]
    assert body["can_move_to_cloud"] is False and body["cloud_ready"] is True and body["cloud_hint"] is None
    store.end(sid)
    _, ended = browser_routes.handle_browser_request("GET", f"sessions/{sid}", None)
    assert ended["status"] == "ended" and ended["live_url"] is None


def test_unknown_or_malformed_ids_are_404(store):
    assert browser_routes.handle_browser_request("GET", "sessions/b_000000000000", None)[0] == 404
    assert browser_routes.handle_browser_request("GET", "sessions/../../etc", None)[0] == 404
    assert browser_routes.replay_file("replays/../../x.mp4") is None


def test_move_needs_a_ready_cloud_browser(store):
    sid = store.ensure("chat1")
    status, body = browser_routes.handle_browser_request("POST", f"sessions/{sid}/move", {"to": "cloud"})
    assert status == 409 and body["ok"] is False and body["move_requested"] is False
    assert "Steel key" in body["error"]


def test_move_flags_the_session_and_reports_the_turn(store, monkeypatch):
    _cloud_ready(monkeypatch, store)
    sid = store.ensure("chat1")
    status, body = browser_routes.handle_browser_request("POST", f"sessions/{sid}/move", {"to": "cloud"})
    assert status == 200 and body == {"ok": True, "move_requested": True, "turn_running": False}
    assert store.view(sid)["move_requested"] is True
    with api_config.ACTIVE_RUNS_LOCK:
        api_config.ACTIVE_RUNS["stream-1"] = {"session_id": "chat1"}
    try:
        _, again = browser_routes.handle_browser_request("POST", f"sessions/{sid}/move", {"to": "cloud"})
        assert again["turn_running"] is True
    finally:
        with api_config.ACTIVE_RUNS_LOCK:
            api_config.ACTIVE_RUNS.pop("stream-1", None)
    bad = browser_routes.handle_browser_request("POST", f"sessions/{sid}/move", {"to": "mars"})
    assert bad[0] == 400


def test_takeover_and_hand_back(store, monkeypatch):
    _cloud_ready(monkeypatch, store)
    sid = store.ensure("chat1")
    refused = browser_routes.handle_browser_request("POST", f"sessions/{sid}/takeover", {"active": True})
    assert refused[0] == 409 and refused[1]["takeover"] is False   # Lightpanda: nothing to take over
    _on_cloud(store, sid)
    status, body = browser_routes.handle_browser_request("POST", f"sessions/{sid}/takeover", {"active": True})
    assert status == 200 and body == {"ok": True, "takeover": True}
    assert store.view(sid)["takeover"] is True and store.takeover_active(sid)
    status, body = browser_routes.handle_browser_request("POST", f"sessions/{sid}/takeover", {"active": False})
    assert body == {"ok": True, "takeover": False} and not store.takeover_active(sid)
    assert browser_routes.handle_browser_request("POST", f"sessions/{sid}/takeover", {"active": "yes"})[0] == 400


def test_replay_is_served_with_range(store):
    sid = store.ensure("chat1")
    data = bytes(range(256)) * 4
    store.replay_path(sid).write_bytes(data)
    store.update(sid, replay_status="ready")
    _, body = browser_routes.handle_browser_request("GET", f"sessions/{sid}", None)
    assert body["replay_url"] == f"/api/browser/replays/{sid}.mp4" and body["replay_status"] == "ready"

    whole = _Handler()
    assert browser_routes.handle_get(whole, urlparse(f"/api/browser/replays/{sid}.mp4"))
    assert whole.status == 200 and whole.sent["Content-Type"] == "video/mp4"
    assert whole.wfile.getvalue() == data and whole.sent["Accept-Ranges"] == "bytes"

    part = _Handler({"Range": "bytes=10-19"})
    assert browser_routes.handle_get(part, urlparse(f"/api/browser/replays/{sid}.mp4"))
    assert part.status == 206 and part.wfile.getvalue() == data[10:20]
    assert part.sent["Content-Range"] == f"bytes 10-19/{len(data)}"

    missing = _Handler()
    assert browser_routes.handle_get(missing, urlparse("/api/browser/replays/b_aaaaaaaaaaaa.mp4"))
    assert missing.status == 404


def test_full_dispatch_through_routes(store):
    """Smoke: the real GET/POST dispatch reaches the browser routes."""
    from api import routes
    sid = store.ensure("chat9")
    h = _Handler()
    assert routes.handle_get(h, urlparse(f"/api/browser/sessions/{sid}")) is True
    assert h.status == 200 and h.payload()["id"] == sid
