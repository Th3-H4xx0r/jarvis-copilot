"""Game-streaming live layer: power_changed/resync carry the Sunshine conn + log path
so the PC can start its watcher, and stale pending connects are reaped.
"""
from __future__ import annotations

from api import game_streaming_routes as R


def _capture_publish(monkeypatch):
    pubs = []
    monkeypatch.setattr(R, "_publish_to", lambda did, topic, data: pubs.append((did, topic, data)))
    return pubs


def test_power_on_publishes_sunshine_and_log_path(monkeypatch):
    pubs = _capture_publish(monkeypatch)
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_sunshine_conn",
                        lambda: {"host": "gpc", "port": 47990, "user": "a", "password": "b", "scheme": "https"})
    monkeypatch.setattr(R, "_settings", lambda: {"log_path": "C:/Sunshine/config/sunshine.log"})
    R.power_changed(True)
    did, topic, data = pubs[-1]
    assert did == "pc" and topic == "game_stream_power"
    assert data["on"] is True
    assert data["sunshine"]["host"] == "gpc" and data["sunshine"]["password"] == "b"
    assert data["log_path"] == "C:/Sunshine/config/sunshine.log"


def test_power_off_payload_omits_credentials(monkeypatch):
    pubs = _capture_publish(monkeypatch)
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_sunshine_conn", lambda: {"host": "gpc", "password": "b"})
    monkeypatch.setattr(R, "_settings", lambda: {})
    R.power_changed(False)
    data = pubs[-1][2]
    assert data["on"] is False
    assert "sunshine" not in data and "log_path" not in data


def test_resync_republishes_desired_power_with_conn(monkeypatch):
    pubs = _capture_publish(monkeypatch)
    monkeypatch.setattr(R, "_sunshine_conn", lambda: {"host": "gpc", "password": "b"})
    monkeypatch.setattr(R, "_settings", lambda: {})
    R._DESIRED["on"] = True
    try:
        R.resync("pc")
    finally:
        R._DESIRED["on"] = None
    did, topic, data = pubs[-1]
    assert did == "pc" and topic == "game_stream_power"
    assert data["on"] is True and data["sunshine"]["host"] == "gpc"


def test_resync_noop_when_no_desired_state(monkeypatch):
    pubs = _capture_publish(monkeypatch)
    R._DESIRED["on"] = None
    R.resync("pc")
    assert pubs == []


def test_reap_drops_only_expired_pendings():
    R._PENDING.clear()
    R._PENDING.append({"pc": "pc", "target": {}, "app": "", "deadline": 10.0})
    R._PENDING.append({"pc": "pc", "target": {}, "app": "", "deadline": 10 ** 12})
    try:
        R._reap(now=100.0)
        assert len(R._PENDING) == 1 and R._PENDING[0]["deadline"] == 10 ** 12
    finally:
        R._PENDING.clear()
