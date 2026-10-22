"""Multi-channel recall: vector + keyword + entity + time, RRF + salience."""
import json

from plugins.memory.jarvis_memory.entities import EntityIndex
from plugins.memory.jarvis_memory.recall import RecallQuery, recall
from plugins.memory.jarvis_memory.store import GLOBAL_NS

from tests.jarvis_memory.conftest_map import CT, NOW, build_venue_store


def _recall(s, e, text, context="", limit=6, **kw):
    q = RecallQuery(text=text, context=context, now=NOW.timestamp(), zone=CT, limit=limit)
    return recall(s, e, q, entity_index=EntityIndex(s, GLOBAL_NS), namespace=GLOBAL_NS, **kw)


def _ids(result):
    return [h.chunk.id for h in result.hits]


def test_venue_query_finds_f1_not_graduation(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    got = _ids(_recall(s, e, "Can you open navigation to the venue"))
    f1 = {ids["f1_trip"], ids["f1_held"], ids["f1_parking"]}
    assert f1 & set(got[:3])
    assert got[0] != ids["grad"]


def test_weekend_query_uses_time_channel(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    res = _recall(s, e, "what am I doing this weekend")
    assert ids["f1_trip"] in _ids(res)[:3]
    assert res.window is not None and res.window.label == "weekend"


def test_one_hop_pulls_linked_memory(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    got = _ids(_recall(s, e, "where is the US GP held"))
    assert ids["f1_held"] in got
    assert ids["f1_pass"] in got  # shares the event, no shared words


def test_min_score_drops_junk(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    got = _ids(_recall(s, e, "Can you open navigation to the venue"))
    assert ids["junk"] not in got


def test_superseded_fact_ranks_below_current(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    got = _ids(_recall(s, e, "where does Pranav live"))
    assert ids["home"] in got
    assert ids["old_home"] not in got or got.index(ids["home"]) < got.index(ids["old_home"])


def test_hidden_never_returned(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    s.set_status([ids["f1_trip"]], "hidden")
    assert ids["f1_trip"] not in _ids(_recall(s, e, "what am I doing this weekend at COTA"))


def test_block_has_dates_and_trace(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    res = _recall(s, e, "where is the race")
    assert res.block.startswith("[Long-term memory]")
    assert "Fri 23 Oct" in res.block
    assert set(res.trace) >= {"channels", "hits", "ms", "entities"}


def test_candidate_ids_restrict(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    got = _ids(_recall(s, e, "parking", candidate_ids={ids["grad"]}))
    assert got == [ids["grad"]]


def test_recall_tool_entity_and_when_filters(tmp_path, monkeypatch):
    from plugins.memory.jarvis_memory import JarvisMemoryProvider, tz
    p = JarvisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 128, "extract": "off",
                                   "proactive": "off", "migrate_builtin": False})
    s, e, ids = build_venue_store(tmp_path / "x")
    p._store, p._embedder = s, e
    p._entity_index = EntityIndex(s, GLOBAL_NS)
    monkeypatch.setattr(tz, "user_zone", lambda: CT)
    p._now = lambda: NOW.timestamp()
    out = json.loads(p.handle_tool_call("memory_recall", {"query": "parking", "entity": "COTA"}))
    got = [r["id"] for r in out["results"]]
    assert ids["f1_parking"] in got and ids["grad"] not in got
    out = json.loads(p.handle_tool_call("memory_recall", {"query": "", "when": "June 12"}))
    assert [r["id"] for r in out["results"]] == [ids["grad"]]
    out = json.loads(p.handle_tool_call("memory_recall", {"query": "where does pranav live"}))
    past = {r["id"]: r.get("past", False) for r in out["results"]}
    assert past[ids["home"]] is False
    assert past.get(ids["old_home"], True) is True
    p.shutdown()
