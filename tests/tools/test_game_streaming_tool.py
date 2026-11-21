"""Game streaming agent tools: JSON returns, game fuzzy-match, clean down-state."""
from __future__ import annotations

import json

import pytest

from tools import game_streaming_tool as T

PID = "13270f21e5f70861ecdfd7ae0a10ff4f"


@pytest.fixture
def fake_api(monkeypatch):
    calls = []

    def _api(method, path, body=None, timeout=10.0):
        calls.append((method, path, body))
        if path.endswith("/pairings"):
            return {"ok": True, "pairings": [{"id": PID, "name": "roth", "address": "192.168.1.69"}],
                    "needs_login": False, "reachable": True}
        if path.endswith("/status"):
            return {"ok": True, "reachable": True, "live": {"active": False},
                    "paired": [{"name": "Mac"}], "apps": [{"name": "Cyberpunk 2077"}]}
        return {"ok": True, "status": "started"}

    monkeypatch.setattr(T, "_api_request", _api)
    return calls


def test_status_returns_json(fake_api):
    out = T.game_stream_status({})
    assert isinstance(out, str)
    assert json.loads(out)["reachable"] is True


def test_start_fuzzy_matches_game(fake_api):
    T.game_stream_start({"target": "Mac", "game": "cyberpunk"})
    start = [c for c in fake_api if c[0] == "POST" and c[1].endswith("/start")][0]
    assert start[2]["game"] == "Cyberpunk 2077"


def test_down_state_surfaces_cleanly(monkeypatch):
    monkeypatch.setattr(T, "_api_request", lambda m, p, body=None, timeout=10.0: {"ok": True, "reachable": False})
    out = T.game_stream_status({})
    assert json.loads(out)["reachable"] is False


def test_every_tool_returns_json_string(fake_api):
    for fn, args in [
        (T.game_stream_status, {}),
        (T.game_stream_start, {"target": "Mac", "game": "Halo"}),
        (T.game_stream_stop, {"target": "Mac"}),
        (T.game_stream_pair, {"device": "Mac", "pin": "1234"}),
        (T.game_stream_unpair, {"device": "Mac"}),
    ]:
        out = fn(args)
        assert isinstance(out, str)
        json.loads(out)


# ── pairing: pending requests + pairing_id ─────────────────────────────────
def test_pair_with_no_waiting_device_says_open_moonlight(monkeypatch):
    calls = []

    def _api(method, path, body=None, timeout=10.0):
        calls.append((method, path, body))
        if path.endswith("/pairings"):
            return {"ok": True, "pairings": [], "needs_login": False, "reachable": True}
        return {"ok": True}

    monkeypatch.setattr(T, "_api_request", _api)
    out = json.loads(T.game_stream_pair({"device": "Mac", "pin": "1234"}))
    assert out["ok"] is False
    assert "no device is waiting" in out["detail"].lower()
    assert "moonlight" in out["detail"].lower()
    assert not [c for c in calls if c[0] == "POST"]          # never submitted a blind PIN


def test_pair_forwards_pin_device_and_pairing_id(fake_api):
    T.game_stream_pair({"device": "Roth", "pin": "1234", "pairing_id": PID})
    post = [c for c in fake_api if c[0] == "POST" and c[1].endswith("/pair")][0]
    assert post[2] == {"device": "Roth", "pin": "1234", "pairing_id": PID}


def test_pair_with_a_waiting_device_submits(fake_api):
    T.game_stream_pair({"pin": "1234"})
    post = [c for c in fake_api if c[0] == "POST" and c[1].endswith("/pair")][0]
    assert post[2]["pin"] == "1234"


def test_pair_offline_pc_surfaces_cleanly(monkeypatch):
    monkeypatch.setattr(T, "_api_request", lambda m, p, body=None, timeout=10.0: {
        "ok": False, "error": "The PC is asleep or offline", "offline": True, "pairings": []})
    out = json.loads(T.game_stream_pair({"pin": "1234"}))
    assert out["ok"] is False and out["offline"] is True


def test_pair_schema_accepts_pairing_id():
    from tools.registry import registry
    schema = registry.get_schema("game_stream_pair")
    assert "pairing_id" in schema["parameters"]["properties"]
