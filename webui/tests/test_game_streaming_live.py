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


def test_resync_with_unknown_state_follows_a_switched_off_power(monkeypatch):
    # Unknown desired state (fresh webui process) follows the Power switch; switched off,
    # the PC is told to stop and no Sunshine login is sent.
    pubs = _capture_publish(monkeypatch)
    monkeypatch.setattr(R, "_enabled", lambda: False)
    R._DESIRED["on"] = None
    R.resync("pc")
    assert len(pubs) == 1
    payload = pubs[0][-1]
    assert payload["on"] is False and "sunshine" not in payload


def test_reap_drops_only_expired_pendings():
    R._PENDING.clear()
    R._PENDING.append({"pc": "pc", "target": {}, "app": "", "deadline": 10.0})
    R._PENDING.append({"pc": "pc", "target": {}, "app": "", "deadline": 10 ** 12})
    try:
        R._reap(now=100.0)
        assert len(R._PENDING) == 1 and R._PENDING[0]["deadline"] == 10 ** 12
    finally:
        R._PENDING.clear()


def test_resync_falls_back_to_power_state_when_desired_unknown(monkeypatch):
    # A fresh webui process hasn't seen power_changed yet; a reconnecting PC must still
    # get the watcher state (from the Power switch) with the Sunshine login.
    from api import game_streaming_routes as R
    sent = []
    monkeypatch.setattr(R, "_publish_to", lambda did, topic, data: sent.append((did, topic, data)))
    monkeypatch.setattr(R, "_enabled", lambda: True)
    monkeypatch.setattr(R, "_settings", lambda: {"user": "root", "password": "pw"})
    monkeypatch.setitem(R._DESIRED, "on", None)
    R.resync("pc")
    assert sent and sent[0][0] == "pc" and sent[0][1] == "game_stream_power"
    assert sent[0][2]["on"] is True
    assert sent[0][2]["sunshine"]["user"] == "root"


def test_subscribe_hook_resyncs_when_pc_subscribes(monkeypatch):
    # Race-free: re-push the power state once the PC's subscription is stored, not on the
    # hello that arrives before it (the push was dropped, so the watcher never restarted).
    from api import game_streaming_routes as R
    from api import device_bridge
    hooks = []
    monkeypatch.setattr(device_bridge, "on_subscribe", lambda cb: hooks.append(cb))
    monkeypatch.setattr(device_bridge, "on_device_event", lambda name, fn: None)
    seen = []
    monkeypatch.setattr(R, "resync", lambda did: seen.append(did))
    R.register_events()
    assert hooks
    hooks[0]("pc", {"game_stream_power": 0})
    hooks[0]("phone", {"pc_stats": 5})
    assert seen == ["pc"]
