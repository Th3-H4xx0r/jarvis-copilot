"""Holo Drop knows the PC: a jc-client on Windows is its own "pc" target, with the Mac's
computer abilities (aim, look, listen) and the same default (open)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import api.holo_drop_routes as routes  # noqa: E402
from test_holo_drop_routes import call, env  # noqa: E402,F401  (fixture)

PC = {"id": "pc-1", "name": "Pranav-Desktop", "kind": "browser", "user_agent": "jc-client/0.1", "os": "windows"}
MAC_JC = {"id": "mac-2", "name": "MacBook", "kind": "browser", "user_agent": "jc-client/0.1"}


def test_jc_client_on_windows_is_pc():
    assert routes._kind(PC) == "pc"


def test_jc_client_on_mac_is_mac():
    assert routes._kind(MAC_JC) == "mac"
    assert routes._kind(dict(MAC_JC, os="macos")) == "mac"


def test_pc_offered_as_target_with_computer_abilities(env, monkeypatch):
    devices = routes._paired() + [PC]
    monkeypatch.setattr(routes, "_paired", lambda: list(devices))
    env.connected.add("pc-1")
    status, body = call("GET", "/api/holo-drop/devices")
    pc = [d for d in body["devices"] if d["id"] == "pc-1"][0]
    assert status == 200
    assert pc["kind"] == "pc" and pc["aim"] is True and pc["default_action"] == "open"
    assert pc["accepts"] == list(routes.KINDS)


def test_offline_pc_drop_is_held_without_waking_a_mac(env, monkeypatch):
    devices = routes._paired() + [PC]
    monkeypatch.setattr(routes, "_paired", lambda: list(devices))
    status, body = call("POST", "/api/holo-drop/drops", body={"target": "pc-1", "kind": "text", "text": "hi"})
    assert status in (200, 201)
    assert env.wakes == []
    assert env.st.get(body["drop"]["id"])["state"] == "held"
