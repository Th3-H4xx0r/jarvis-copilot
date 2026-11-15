"""PC Stats tools: dashboard edits go through the server (validated), widgets auto-place, queries."""
from __future__ import annotations

import json

import pytest

import tools.pc_stats_tool as t

BOARD = {"id": "overview", "name": "Overview", "auto": None, "rev": 3, "widgets": [
    {"id": "gpu", "kind": "hero", "x": 0, "y": 0, "w": 6, "h": 4, "readings": ["gpu.load"], "style": {}},
    {"id": "cpu", "kind": "hero", "x": 6, "y": 0, "w": 6, "h": 4, "readings": ["cpu.load"], "style": {}},
]}


@pytest.fixture
def api(monkeypatch):
    calls = []
    store = {"board": json.loads(json.dumps(BOARD))}

    def fake(method, path, body=None, timeout=10.0):
        calls.append((method, path, body))
        if method == "GET" and path == "/api/pc-stats/dashboards":
            return {"dashboards": [store["board"]]}
        if method == "PUT":
            d = body["dashboard"]
            if any(w.get("kind") not in ("hero", "number", "chart", "bars", "ring", "sparkline", "text", "session", "moments")
                   for w in d["widgets"]):
                return {"errors": ["widget 'bad': kind must be one of …"]}
            if body["rev"] != store["board"]["rev"]:
                return {"error": "changed elsewhere", "dashboard": store["board"]}
            store["board"] = {**d, "rev": body["rev"] + 1}
            return {"dashboard": store["board"]}
        if path.startswith("/api/pc-stats/live"):
            return {"online": True, "at": 1_800_000_000, "sample": {"r": {"gpu.temp": 67}, "game": None}, "estimated": []}
        if path.startswith("/api/pc-stats/history"):
            return {"points": [[1_800_000_000, 60, 55, 70], [1_800_000_600, 65, 60, 81]]}
        return {}

    monkeypatch.setattr(t, "_api_request", fake)
    return calls, store


def test_tool_rejects_invalid_widget(api):
    calls, store = api
    out = json.loads(t.pc_dashboard({"action": "add_widget", "widget": {"id": "bad", "kind": "pie"}}))
    assert out["ok"] is False and out["errors"]
    assert store["board"]["rev"] == 3 and len(store["board"]["widgets"]) == 2


def test_add_widget_autoplaces(api):
    _, store = api
    out = json.loads(t.pc_dashboard({"action": "add_widget",
                                     "widget": {"kind": "number", "w": 4, "h": 2, "readings": ["gpu.temp"]}}))
    assert out["ok"] is True
    added = store["board"]["widgets"][-1]
    assert (added["x"], added["y"]) == (0, 4)          # first free row under the two heroes
    assert store["board"]["rev"] == 4


def test_update_widget_merges_style(api):
    _, store = api
    json.loads(t.pc_dashboard({"action": "update_widget", "widget_id": "gpu", "widget": {"style": {"color": "#FF0000"}, "w": 6}}))
    gpu = next(w for w in store["board"]["widgets"] if w["id"] == "gpu")
    assert gpu["style"] == {"color": "#FF0000"} and gpu["kind"] == "hero"


def test_query_now_and_history(api):
    now = json.loads(t.pc_stats_query({"what": "now"}))
    assert now["ok"] and now["readings"]["gpu.temp"] == 67
    hist = json.loads(t.pc_stats_query({"what": "history", "key": "gpu.temp", "hours": 1}))
    assert hist["max"] == 81 and hist["avg"] == 62.5 and len(hist["points"]) == 2
    assert json.loads(t.pc_stats_query({"what": "history"}))["ok"] is False
