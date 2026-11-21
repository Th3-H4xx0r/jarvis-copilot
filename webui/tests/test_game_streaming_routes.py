"""Game streaming routes: status, start (awake/pending), pair, event."""
from __future__ import annotations

import pytest

from api import game_streaming_routes as R
from api.game_streaming_store import GameStreamingStore


class Req:
    def __init__(self, method, sub, body=None, query=None):
        self.method = method
        self.sub = sub
        self.body = body or {}
        self.query = query or {}
        self.replied = None

    def reply(self, code, data):
        self.replied = (code, data)
        return True


@pytest.fixture
def wired(tmp_path, monkeypatch):
    st = GameStreamingStore(tmp_path)
    calls = []
    monkeypatch.setattr(R, "store", lambda: st)
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_sunshine_conn", lambda: {"host": "gpc", "port": 47990, "user": "a", "password": "b"})
    monkeypatch.setattr(R, "_targets", lambda: [{"name": "Mac", "kind": "mac", "host": "gpc"}])
    monkeypatch.setattr(R, "_current_game", lambda: None)
    monkeypatch.setattr(R, "_wake_pc", lambda: calls.append(("wake",)) or True)
    monkeypatch.setattr(R, "_device_for_kind", lambda kind: "mac-dev")

    def fake_invoke(did, skill, args, timeout=20):
        calls.append((did, skill, args))
        if skill == "game_stream_status":
            return {"ok": True, "data": {"reachable": True, "paired": [{"name": "Mac", "uuid": "u1"}], "apps": [{"name": "Halo"}]}}
        return {"ok": True}

    monkeypatch.setattr(R, "_invoke", fake_invoke)
    R._PENDING.clear()
    return st, calls, monkeypatch


def _online(monkeypatch, ids):
    monkeypatch.setattr(R, "_connected", lambda: ids)


def test_status_reports_down_when_bridge_offline(wired):
    st, calls, mp = wired
    _online(mp, [])
    req = Req("GET", "/status")
    R.route(req)
    assert req.replied[0] == 200
    assert req.replied[1]["reachable"] is False


def test_start_awake_pc_dispatches_connect(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    req = Req("POST", "/start", {"target": "Mac", "game": "Halo"})
    R.route(req)
    skills = [c[1] for c in calls if len(c) == 3]
    assert "game_stream_ready" in skills
    assert "game_stream_connect" in skills


def test_start_asleep_returns_pending_and_requests_wake(wired):
    st, calls, mp = wired
    _online(mp, [])
    req = Req("POST", "/start", {"target": "Mac", "game": "Halo"})
    R.route(req)
    assert req.replied[1]["status"] == "pending"
    assert ("wake",) in calls
    assert len(R._PENDING) == 1


def test_pending_connect_completes_on_awake_event(wired):
    st, calls, mp = wired
    _online(mp, [])
    R.route(Req("POST", "/start", {"target": "Mac", "game": "Halo"}))
    calls.clear()
    R.complete_pending("pc")
    skills = [c[1] for c in calls if len(c) == 3]
    assert "game_stream_connect" in skills
    assert len(R._PENDING) == 0


def test_pending_times_out(wired):
    st, calls, mp = wired
    R._PENDING.append({"pc": "pc", "target": {"kind": "mac", "host": "gpc"}, "app": "Halo",
                       "srs": False, "deadline": 0.0})
    R._reap(now=10_000_000_000.0)
    assert len(R._PENDING) == 0


def test_start_with_local_game_sets_stream_running_session(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_current_game", lambda: "Halo")
    R.route(Req("POST", "/start", {"target": "Mac", "game": "Doom"}))
    connect = [c for c in calls if len(c) == 3 and c[1] == "game_stream_connect"][0]
    assert connect[2]["stream_running_session"] is True


def test_pair_forwards_pin(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    R.route(Req("POST", "/pair", {"device": "Mac", "pin": "1234"}))
    pair = [c for c in calls if len(c) == 3 and c[1] == "game_stream_pair"][0]
    assert pair[2]["pin"] == "1234"
