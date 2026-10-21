"""memory_recall's person / source / date filters — how a past iMessage chat is looked up."""
import json
from datetime import datetime
from zoneinfo import ZoneInfo

from plugins.memory.jarvis_memory import JarvisMemoryProvider, _RECALL_SCHEMA
from plugins.memory.jarvis_memory.recall import parse_when

LA = ZoneInfo("America/Los_Angeles")


def _provider(tmp_path):
    p = JarvisMemoryProvider()
    p.initialize("sess-1", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 64})
    return p


def _ts(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=LA).timestamp()


def _seed(p):
    s, ns = p._store, p._namespace
    s.add_chunk(ns, "iMessage with Sam Lee (+15105550000) — Mon 19 Oct 2026\n"
                    "Participants: Me, Sam Lee\n[18:02] Sam Lee: dinner at the taco place?",
                "imessage:chat1:10-12", _ts(2026, 10, 19, 18, 2), 1.0, "imessage,conversation")
    s.add_chunk(ns, "iMessage with Sam Lee (+15105550000) — Mon 19 Oct 2026\n"
                    "Participants: Me, Sam Lee\n[23:30] Sam Lee: my address is 12 Oak St",
                "imessage:chat1:13-14", _ts(2026, 10, 19, 23, 30), 1.0, "imessage,conversation")
    s.add_chunk(ns, "iMessage with Priya Rao (+14155550000) — Sun 18 Oct 2026\n"
                    "Participants: Me, Priya Rao\n[09:00] Priya Rao: taco tuesday?",
                "imessage:chat2:1-3", _ts(2026, 10, 18, 9), 1.0, "imessage,conversation")
    s.add_chunk(ns, "Live conversation on Monday 19 October 2026 with Sam Lee about tacos",
                "live:abc:1-4", _ts(2026, 10, 19, 12), 1.0, "live,conversation")
    s.add_chunk(ns, "Pranav likes tacos", "tool:memory_store", _ts(2026, 10, 1, 12), 1.0, "fact")


def _recall(p, **args):
    out = json.loads(p.handle_tool_call("memory_recall", args))
    assert out["ok"], out
    return out["results"]


def test_query_optional_in_schema():
    props = _RECALL_SCHEMA["parameters"]["properties"]
    assert {"source", "person", "since", "until"} <= set(props)
    assert "query" not in _RECALL_SCHEMA["parameters"].get("required", [])


def test_source_filter_returns_only_imessage(tmp_path):
    p = _provider(tmp_path)
    _seed(p)
    hits = _recall(p, query="taco", source="imessage", limit=10)
    assert hits and all(h["source"].startswith("imessage:") for h in hits)
    p.shutdown()


def test_person_filter_matches_header_tokens_any_order(tmp_path):
    p = _provider(tmp_path)
    _seed(p)
    hits = _recall(p, person="lee sam", limit=10)
    # Live names its speakers in the header too, so both kinds come back.
    assert {h["source"] for h in hits} == {"imessage:chat1:10-12", "imessage:chat1:13-14",
                                           "live:abc:1-4"}
    p.shutdown()


def test_empty_query_with_filters_returns_time_order(tmp_path):
    p = _provider(tmp_path)
    _seed(p)
    hits = _recall(p, query="", source="imessage", limit=10)
    assert [h["source"] for h in hits] == ["imessage:chat2:1-3", "imessage:chat1:10-12",
                                           "imessage:chat1:13-14"]
    p.shutdown()


def test_query_with_filters_ranks_within_candidates(tmp_path):
    p = _provider(tmp_path)
    _seed(p)
    hits = _recall(p, query="address", person="Sam", source="imessage", limit=1)
    assert hits[0]["source"] == "imessage:chat1:13-14"
    p.shutdown()


def test_until_bare_date_means_end_of_day_local(tmp_path, monkeypatch):
    import jarviscopilot_time
    monkeypatch.setattr(jarviscopilot_time, "get_timezone", lambda: LA)
    p = _provider(tmp_path)
    _seed(p)
    hits = _recall(p, source="imessage", since="2026-10-19", until="2026-10-19", limit=10)
    assert {h["source"] for h in hits} == {"imessage:chat1:10-12", "imessage:chat1:13-14"}
    assert parse_when("2026-10-19", end_of_day=True, zone=LA) > _ts(2026, 10, 19, 23, 59)
    assert parse_when("2026-10-19", end_of_day=False, zone=LA) == _ts(2026, 10, 19, 0)
    p.shutdown()


def test_results_include_created_at_and_source(tmp_path):
    p = _provider(tmp_path)
    _seed(p)
    hit = _recall(p, query="address", source="imessage", limit=1)[0]
    assert hit["source"] == "imessage:chat1:13-14"
    assert hit["created_at"].startswith("2026-10-")
    p.shutdown()


def test_plain_query_still_works(tmp_path):
    p = _provider(tmp_path)
    _seed(p)
    assert _recall(p, query="tacos", limit=10)
    p.shutdown()


def test_filtered_query_reaches_old_memories_past_500(tmp_path):
    """source='imessage' must still find an old fact behind hundreds of newer memories."""
    p = _provider(tmp_path)
    s, ns = p._store, p._namespace
    s.add_chunk(ns, "Sam Lee's address is 12 Oak St, Oakland", "imessage:c:fact:1-1:f",
                _ts(2026, 1, 1, 9), 1.0, "imessage,fact")
    for i in range(520):
        s.add_chunk(ns, f"iMessage chatter number {i} about lunch", f"imessage:c:{i}-{i}:p1",
                    _ts(2026, 6, 1, 9) + i, 1.0, "imessage,conversation")
    hits = _recall(p, query="Sam address Oak", source="imessage", limit=3)
    assert any("12 Oak St" in h["body"] for h in hits)
    p.shutdown()
