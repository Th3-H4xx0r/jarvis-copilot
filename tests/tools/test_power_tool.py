"""Jarvis's power_list / power_set tools: they talk to the webui over the host-signed loopback."""
from __future__ import annotations

import json

import pytest

from tools import power_tool


@pytest.fixture()
def calls(monkeypatch):
    seen = []
    replies = {}

    def fake(method, path, body=None, timeout=10.0):
        seen.append((method, path, body))
        return replies.get((method, path), {"_error": "no reply"})

    monkeypatch.setattr(power_tool, "_api_request", fake)
    return seen, replies


def test_power_list_fields(calls):
    seen, replies = calls
    replies[("GET", "/api/power")] = {"version": "v", "integrations": [{
        "id": "dashcam", "name": "Dashcam", "enabled": True, "protected": False,
        "status_line": "Idle", "error": None, "settings": {"a": 1},
        "settings_schema": [{"key": "a"}], "surfaces": ["x"], "links": [], "native": {},
        "summary": "s", "icon": "camera", "has_card": True, "has_page": True, "space": "dashcam"}]}
    out = json.loads(power_tool.power_list({}))
    [row] = out["integrations"]
    assert row["id"] == "dashcam" and row["settings"] == {"a": 1}
    assert not {"surfaces", "links", "native", "has_card", "has_page"} & set(row)


def test_power_set_pending_message(calls):
    seen, replies = calls
    replies[("POST", "/api/power/car")] = {"ok": False, "pending": {"id": "abc"}}
    out = json.loads(power_tool.power_set({"id": "car", "enabled": False}))
    assert seen[-1] == ("POST", "/api/power/car", {"enabled": False, "client": "jarvis"})
    assert out["waiting"] == "Waiting for Face ID on your iPhone"


def test_power_set_on_mentions_next_chat(calls):
    seen, replies = calls
    replies[("POST", "/api/power/kanban")] = {"ok": True, "row": {"id": "kanban", "enabled": True}}
    out = json.loads(power_tool.power_set({"id": "kanban", "enabled": True}))
    assert out["ok"] is True
    assert out["note"] == "Its tools are available from your next chat."


def test_power_set_needs_something_to_do(calls):
    out = json.loads(power_tool.power_set({"id": "kanban"}))
    assert "error" in out
