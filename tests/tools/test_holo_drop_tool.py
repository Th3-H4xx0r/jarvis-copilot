"""Jarvis's holo_drop tool picks the device by name/kind and posts the drop."""
from __future__ import annotations

import json

from tools import holo_drop_tool as t

DEVICES = {"devices": [{"id": "mac-1", "name": "MacBook", "kind": "mac", "online": True},
                       {"id": "iphone-1", "name": "Pranav's iPhone", "kind": "iphone", "online": False}]}


def test_link_to_mac(monkeypatch):
    sent = []

    def fake(method, path, body=None, timeout=10.0):
        if method == "GET":
            return DEVICES
        sent.append((path, body))
        return {"drop": {"id": "d1", "state": "delivered"}}

    monkeypatch.setattr(t, "_api_request", fake)
    out = json.loads(t.holo_drop({"target": "my mac", "url": "https://x.y"}))
    assert out["ok"] is False                      # "my mac" isn't a name or kind…
    out = json.loads(t.holo_drop({"target": "mac", "url": "https://x.y"}))
    assert out["ok"] is True and out["to"] == "MacBook"
    assert sent[-1] == ("/api/holo-drop/drops", {"kind": "link", "target": "mac-1", "url": "https://x.y", "text": ""})


def test_unknown_device_lists_choices(monkeypatch):
    monkeypatch.setattr(t, "_api_request", lambda *a, **k: DEVICES)
    out = json.loads(t.holo_drop({"target": "toaster", "text": "hi"}))
    assert "MacBook" in out["error"]
