"""End-to-end: real routes + real store + real alerts wired together; only the bridge (_invoke)
and the phone push cross a process boundary and are faked. Verifies the resolution chain:
status updates the store, PC events update live state + fire alerts, start dispatches, pair forwards.
"""
from __future__ import annotations

import pytest

from api import game_streaming_routes as R
from api import game_streaming_alerts as A


class Req:
    def __init__(self, method, sub, body=None):
        self.method, self.sub, self.body, self.query, self.replied = method, sub, body or {}, {}, None

    def reply(self, code, data):
        self.replied = (code, data)
        return True


@pytest.fixture
def chain(monkeypatch):
    calls, pushes = [], []

    def fake_invoke(did, skill, args, timeout=20):
        calls.append((skill, args))
        if skill == "game_stream_status":
            return {"ok": True, "data": {"reachable": True,
                    "paired": [{"name": "Mac", "uuid": "u1"}], "apps": [{"name": "Cyberpunk 2077"}]}}
        return {"ok": True}

    monkeypatch.setattr(R, "_invoke", fake_invoke)
    monkeypatch.setattr(R, "_connected", lambda: ["pc"])
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_sunshine_conn", lambda: {"host": "gpc", "port": 47990, "user": "a", "password": "b"})
    monkeypatch.setattr(R, "_targets", lambda: [{"name": "Mac", "kind": "mac", "host": "gpc"}])
    monkeypatch.setattr(R, "_device_for_kind", lambda kind: "mac-dev")
    monkeypatch.setattr(R, "_current_game", lambda: None)
    monkeypatch.setattr(A, "_push", lambda title, body, data=None: pushes.append((title, body)))
    A.reset()
    R._PENDING.clear()
    return calls, pushes


def test_status_persists_paired_to_real_store(chain):
    R.route(Req("GET", "/status"))
    assert {d["name"] for d in R.store().get_paired()} == {"Mac"}


def test_event_updates_live_and_alerts(chain):
    calls, pushes = chain
    R.route(Req("POST", "/event", {"kind": "stream_start", "client": "Mac", "app": "Halo"}))
    assert R.store().get_live()["active"] is True
    R.route(Req("POST", "/event", {"kind": "device_connect", "client": "Intruder", "unknown": True}))
    assert any("Intruder" in b for _, b in pushes)


def test_start_awake_and_pair_forward(chain):
    calls, pushes = chain
    R.route(Req("POST", "/start", {"target": "Mac", "game": "Cyberpunk 2077"}))
    R.route(Req("POST", "/pair", {"device": "Mac", "pin": "4321"}))
    skills = [c[0] for c in calls]
    assert "game_stream_ready" in skills and "game_stream_connect" in skills
    pair = [c for c in calls if c[0] == "game_stream_pair"][0]
    assert pair[1]["pin"] == "4321"
