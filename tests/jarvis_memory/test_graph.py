"""The memory map's graph: you at the center, neighbours, fixes, recalls."""
import pytest

from plugins.memory.jarvis_memory import graph
from plugins.memory.jarvis_memory.store import GLOBAL_NS

from tests.jarvis_memory.conftest_map import NOW, build_venue_store, ts


@pytest.fixture
def venue(tmp_path):
    return build_venue_store(tmp_path)


def _ids(nodes):
    return {n["id"] for n in nodes}


def test_center_me_lists_busiest_entities_with_shared_links(venue):
    s, _e, ids = venue
    g = graph.build(s, GLOBAL_NS, center="me")
    assert g["center"] == {"id": "me", "label": "You", "type": "me"}
    w = {n["id"]: n["weight"] for n in g["nodes"]}
    assert w[ids["e_f1"]] == 4 and w[ids["e_cota"]] == 3 and w[ids["e_sid"]] == 1
    edges = {(e["a"], e["b"]): e["weight"] for e in g["edges"]}
    assert edges[("me", ids["e_f1"])] == 4
    assert edges[tuple(sorted((ids["e_f1"], ids["e_cota"])))] == 3


def test_filters_type_time_and_source(venue):
    s, _e, ids = venue
    assert _ids(graph.build(s, GLOBAL_NS, center="me", types=["person"])["nodes"]) == {ids["e_sid"]}
    assert graph.build(s, GLOBAL_NS, center="me", since=ts(2026, 10, 30, 0, 0))["nodes"] == []
    assert graph.build(s, GLOBAL_NS, center="me", source="imessage")["nodes"] == []
    assert _ids(graph.build(s, GLOBAL_NS, center="me", source="test")["nodes"]) >= {ids["e_f1"]}


def test_hidden_and_superseded_memories_do_not_count(venue):
    s, _e, ids = venue
    s.set_status([ids["f1_trip"], ids["f1_held"], ids["f1_parking"]], "hidden")
    w = {n["id"]: n["weight"] for n in graph.build(s, GLOBAL_NS, center="me")["nodes"]}
    assert w[ids["e_f1"]] == 1 and ids["e_cota"] not in w


def test_center_entity_returns_neighbours(venue):
    s, _e, ids = venue
    g = graph.build(s, GLOBAL_NS, center=ids["e_f1"])
    assert g["center"]["label"] == "F1 US Grand Prix"
    assert _ids(g["nodes"]) == {ids["e_cota"], ids["e_sid"]}
    assert {(e["a"], e["b"]) for e in g["edges"]} >= {tuple(sorted((ids["e_f1"], ids["e_cota"])))}


def test_entity_detail(venue):
    s, _e, ids = venue
    d = graph.entity_detail(s, ids["e_cota"])
    assert d["entity"]["label"] == "Circuit of the Americas" and d["entity"]["aliases"] == ["COTA"]
    assert [m["id"] for m in d["memories"]][0] == ids["f1_parking"]  # newest first
    assert d["memories"][0]["role"] == "venue"
    assert {n["id"] for n in d["neighbors"]} == {ids["e_f1"], ids["e_sid"]}


def test_rename_pin_and_rename_onto_existing_merges(venue):
    s, _e, ids = venue
    e = graph.update_entity(s, ids["e_sid"], label="Sid P", aliases=["Siddharth"], pinned=True)
    assert e["label"] == "Sid P" and "Sid Patel" in e["aliases"] and e["pinned"]
    # A later write naming the new name lands on the same node, not a duplicate.
    assert s.upsert_entity({"type": "person", "canonical": "Sid P"}) == ids["e_sid"]
    other = s.upsert_entity({"type": "person", "canonical": "Sai Kumar"})
    s.link(ids["f1_pass"], other, "with")
    merged = graph.update_entity(s, other, label="Sid P")
    assert merged["id"] == ids["e_sid"]
    assert s.get_entities([other]) == {}
    assert ids["f1_pass"] in s.memories_for_entities([ids["e_sid"]], 10)


def test_merge_requires_same_type(venue):
    s, _e, ids = venue
    with pytest.raises(ValueError):
        graph.merge(s, ids["e_cota"], ids["e_sid"])
    sid2 = s.upsert_entity({"type": "person", "canonical": "Siddharth Patel"})
    s.link(ids["f1_held"], sid2, "with")
    e = graph.merge(s, sid2, ids["e_sid"])
    assert "Siddharth Patel" in e["aliases"]
    assert set(s.memories_for_entities([ids["e_sid"]], 10)) == {ids["f1_trip"], ids["f1_held"]}


def test_unlink(venue):
    s, _e, ids = venue
    graph.unlink(s, ids["f1_parking"], ids["e_cota"])
    assert ids["f1_parking"] not in s.memories_for_entities([ids["e_cota"]], 10)


def test_recalls_and_highlight(venue):
    s, _e, ids = venue
    s.add_trace("sess", "where is the race", "[Long-term memory] …",
                {"hits": [[ids["f1_held"], 0.2], [ids["f1_parking"], 0.1]], "ms": 12})
    s.add_trace("sess", "hi", "", {"hits": [], "ms": 3})
    s.add_trace("other", "parking?", "x", {"hits": [[ids["f1_parking"], 0.3]], "ms": 5})
    rec = graph.recalls(s, limit=10)
    assert [r["query"] for r in rec] == ["parking?", "where is the race"]
    rec = graph.recalls(s, limit=10, session_id="sess")
    assert rec[0]["memory_ids"] == [ids["f1_held"], ids["f1_parking"]]
    assert set(rec[0]["entity_ids"]) == {ids["e_f1"], ids["e_cota"]}
    g = graph.highlight(s, GLOBAL_NS, rec[0]["id"])
    assert set(g["highlight"]) == {ids["e_f1"], ids["e_cota"]} and _ids(g["nodes"]) >= set(g["highlight"])


def test_rename_onto_existing_keeps_the_aliases_typed_with_it(venue):
    s, _e, ids = venue
    other = s.upsert_entity({"type": "person", "canonical": "Sai Kumar"})
    merged = graph.update_entity(s, other, label="Sid Patel", aliases=["Saikumar"], pinned=True)
    assert merged["id"] == ids["e_sid"]
    assert "Saikumar" in merged["aliases"] and merged["pinned"] is True


def test_center_edges_survive_a_type_filter_that_excludes_the_center(venue):
    s, _e, ids = venue
    g = graph.build(s, GLOBAL_NS, center=ids["e_f1"], types=["place", "person"])
    touching = {e["b"] if e["a"] == ids["e_f1"] else e["a"] for e in g["edges"] if ids["e_f1"] in (e["a"], e["b"])}
    assert touching == {n["id"] for n in g["nodes"]}


def test_merge_requires_same_namespace(venue):
    s, _e, ids = venue
    other = s.upsert_entity({"namespace": "user:9", "type": "person", "canonical": "Sid Patel"})
    with pytest.raises(ValueError):
        graph.merge(s, other, ids["e_sid"])


def test_a_merged_away_name_still_finds_the_survivor(venue):
    s, _e, ids = venue
    sid2 = s.upsert_entity({"type": "person", "canonical": "Siddharth Patel"})
    graph.merge(s, sid2, ids["e_sid"])
    assert s.upsert_entity({"type": "person", "canonical": "Siddharth Patel"}) == ids["e_sid"]
