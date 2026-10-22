"""HTTP handlers for the memory map (graph, entity, fixes, recalls)."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.memory_graph as mg  # noqa: E402


@pytest.fixture
def out(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from plugins.memory.jarvis_memory import external
    external._handles.clear()
    calls = []
    import api.helpers as helpers
    monkeypatch.setattr(helpers, "j", lambda h, payload, status=200, **k: calls.append((status, payload)))
    monkeypatch.setattr(helpers, "bad", lambda h, msg, status=400: calls.append((status, {"error": msg})))
    store = external._open()[0]
    a = store.add_chunk("global", "Going to the F1 race at COTA with Sid", "imessage:g:1-1:f", 1.0, 1.0)
    f1 = store.upsert_entity({"type": "event", "canonical": "F1 US Grand Prix"})
    sid = store.upsert_entity({"type": "person", "canonical": "Sid Patel"})
    store.link(a, f1, "event")
    store.link(a, sid, "with")
    store.add_trace("sess1", "where is the race", "[Long-term memory]", {"hits": [[a, 0.2]], "ms": 9})
    return calls, store, {"a": a, "f1": f1, "sid": sid}


def _get(path):
    return urlparse(path)


def test_graph_me_and_filters(out):
    calls, store, ids = out
    mg.handle_get(None, _get("/api/jarvis-memory/graph?center=me&types=person,event&source=imessage"))
    status, body = calls[-1]
    assert status == 200 and {n["id"] for n in body["nodes"]} == {ids["f1"], ids["sid"]}
    mg.handle_get(None, _get("/api/jarvis-memory/graph?center=me&types=place"))
    assert calls[-1][1]["nodes"] == []
    mg.handle_get(None, _get(f"/api/jarvis-memory/graph?center={ids['f1']}"))
    assert [n["id"] for n in calls[-1][1]["nodes"]] == [ids["sid"]]
    mg.handle_get(None, _get("/api/jarvis-memory/graph?center=e_nope"))
    assert calls[-1][0] == 404


def test_entity_fix_merge_unlink(out):
    calls, store, ids = out
    mg.handle_get(None, _get(f"/api/jarvis-memory/entity?id={ids['sid']}"))
    assert calls[-1][1]["entity"]["label"] == "Sid Patel" and calls[-1][1]["memories"][0]["role"] == "with"
    mg.handle_post(None, _get("/api/jarvis-memory/entity"), {"id": ids["sid"], "pinned": True, "aliases": ["Sid"]})
    assert calls[-1][1]["entity"]["pinned"] is True
    other = store.upsert_entity({"type": "person", "canonical": "Siddharth"})
    mg.handle_post(None, _get("/api/jarvis-memory/entity/merge"), {"from": other, "into": ids["sid"]})
    assert calls[-1][0] == 200 and "Siddharth" in calls[-1][1]["entity"]["aliases"]
    mg.handle_post(None, _get("/api/jarvis-memory/entity/merge"), {"from": ids["f1"], "into": ids["sid"]})
    assert calls[-1][0] == 400
    mg.handle_post(None, _get("/api/jarvis-memory/entity/unlink"), {"memory_id": ids["a"], "entity_id": ids["sid"]})
    assert calls[-1] == (200, {"ok": True})


def test_recalls_and_highlight(out):
    calls, store, ids = out
    mg.handle_get(None, _get("/api/jarvis-memory/recalls?session_id=sess1"))
    [rec] = calls[-1][1]["recalls"]
    assert rec["query"] == "where is the race" and rec["memory_ids"] == [ids["a"]]
    mg.handle_get(None, _get(f"/api/jarvis-memory/graph/highlight?recall={rec['id']}"))
    assert set(calls[-1][1]["highlight"]) == {ids["f1"], ids["sid"]}
    mg.handle_get(None, _get("/api/jarvis-memory/graph/highlight?recall=abc"))
    assert calls[-1][0] == 400


def test_unknown_path_is_not_handled(out):
    assert mg.handle_get(None, _get("/api/jarvis-memory/other")) is None
