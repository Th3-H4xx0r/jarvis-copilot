"""Game streaming agent tools: JSON returns, game fuzzy-match, clean down-state."""
from __future__ import annotations

import json

import pytest

from tools import game_streaming_tool as T


@pytest.fixture
def fake_api(monkeypatch):
    calls = []

    def _api(method, path, body=None, timeout=10.0):
        calls.append((method, path, body))
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
