"""Game streaming scheduled trigger: creates a cron job that runs game_stream_start."""
from __future__ import annotations

from api import game_streaming_routes as R


class Req:
    def __init__(self, method, sub, body=None):
        self.method = method
        self.sub = sub
        self.body = body or {}
        self.query = {}
        self.replied = None

    def reply(self, code, data):
        self.replied = (code, data)
        return True


def test_schedule_stream_creates_job(monkeypatch):
    seen = {}
    monkeypatch.setattr(R, "_create_job", lambda **kw: (seen.update(kw) or {"id": "j1"}))
    R.schedule_stream("every monday 9am", "Mac", "Halo")
    assert seen["schedule"] == "every monday 9am"
    assert "Halo" in seen["prompt"] and "Mac" in seen["prompt"]
    assert seen["integration"] == "game-streaming"
    assert "game_streaming" in (seen.get("enabled_toolsets") or [])


def test_schedule_route(monkeypatch):
    monkeypatch.setattr(R, "_create_job", lambda **kw: {"id": "j1", "name": kw.get("name")})
    monkeypatch.setattr(R, "store", lambda: None)
    req = Req("POST", "/schedule", {"when": "0 9 * * *", "target": "Mac", "game": "Halo"})
    assert R.route(req) is True
    assert req.replied[0] == 200 and req.replied[1]["ok"] is True
