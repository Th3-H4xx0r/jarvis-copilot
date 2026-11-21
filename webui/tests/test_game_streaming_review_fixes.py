"""Review fixes: envelope unwrap (C1), targets JSON parse (C2), pending stale-drop (I1), Mac-offline (M1)."""
from __future__ import annotations

from api import game_streaming_routes as R


def test_invoke_unwraps_skill_envelope(monkeypatch):
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "invoke_skill",
                        lambda did, skill, args, timeout=20: {"ok": True, "result": {"ok": True, "data": {"reachable": True}}})
    assert R._invoke("pc", "game_stream_status", {}) == {"ok": True, "data": {"reachable": True}}


def test_targets_parses_json_string(monkeypatch):
    monkeypatch.setattr(R, "_settings", lambda: {"targets": '[{"name":"Mac","kind":"mac","host":"gpc"}]'})
    assert R._targets() == [{"name": "Mac", "kind": "mac", "host": "gpc"}]
    monkeypatch.setattr(R, "_settings", lambda: {"targets": "not json"})
    assert R._targets() == []


def test_complete_pending_drops_expired_without_dispatch(monkeypatch):
    R._PENDING.clear()
    calls = []
    monkeypatch.setattr(R, "_dispatch_connect", lambda pc, t, a, s: calls.append(1))
    R._PENDING.append({"pc": "pc", "target": {"kind": "mac", "host": "g"}, "app": "H", "srs": False, "deadline": 0.0})
    R.complete_pending("pc")
    assert calls == [] and R._PENDING == []


def test_mac_offline_returns_clear_message(monkeypatch):
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_connected", lambda: ["pc"])          # no darwin device
    monkeypatch.setattr(R, "_device_os", lambda d: "windows")
    monkeypatch.setattr(R, "_invoke", lambda *a, **k: {"ok": True})
    res = R._dispatch_connect("pc", {"kind": "mac", "host": "g"}, "Halo", False)
    assert res["ok"] is False and "mac" in res["detail"].lower() and "offline" in res["detail"].lower()
