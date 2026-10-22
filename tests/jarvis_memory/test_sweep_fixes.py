"""Fixes from the bug sweep of the memory map (each reproduces a finding)."""
import json
import threading
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from plugins.memory.jarvis_memory import brief, cleanup, enrich
from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore

from tests.jarvis_memory.conftest_map import NOW, build_venue_store, ts

CT = ZoneInfo("America/Chicago")


@pytest.fixture(autouse=True)
def _clean_brief():
    brief.reset()
    yield
    brief.reset()


def _store(tmp_path, name="memory.db"):
    return MemoryStore(tmp_path / "memory" / name, tmp_path / "memory" / "vault")


# C2: a forgotten memory's event leaves the brief
def test_event_with_no_memory_left_is_not_coming_up(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk(GLOBAL_NS, "Dinner with Priya on Saturday", "imessage:p:1-1:f", NOW.timestamp(), 1.0)
    eid = s.upsert_entity({"type": "event", "canonical": "Dinner with Priya",
                           "event_start": ts(2026, 10, 24, 19, 0)})
    s.link(cid, eid, "event")
    assert "Dinner with Priya" in brief.build(s, GLOBAL_NS, now=NOW)
    s.forget_source(source_prefix="imessage:p:")
    assert "Dinner with Priya" not in brief.build(s, GLOBAL_NS, now=NOW)


# C3: forgetting the kept memory also removes the hidden copy merged into it + its traces
def test_forget_removes_merged_hidden_copies_and_traces(tmp_path):
    s = _store(tmp_path)
    e = FakeEmbedder(dim=64)
    keep = s.add_chunk(GLOBAL_NS, "My PIN is 4411", "fact:a", 1.0, 1.0,
                       embedding=e.embed_one("My PIN is 4411"), signature=e.signature, dim=e.dim)
    copy = s.add_chunk(GLOBAL_NS, "My PIN is 4411.", "fact:b", 2.0, 1.0,
                       embedding=e.embed_one("My PIN is 4411"), signature=e.signature, dim=e.dim)
    s.dequeue([keep, copy])
    cleanup.run(s, e, zone=CT, complete=lambda p, n: "[]")
    s.add_trace("sess", "what's my pin", "[Long-term memory]\n- My PIN is 4411", {})
    s.delete_chunk(keep)
    assert s.get_chunks([copy]) == []
    assert all("4411" not in t["injected"] for t in s.recent_traces(10))


# C5: two map loops never send the same memory twice
def test_two_drains_share_the_queue(tmp_path):
    a, b = _store(tmp_path), _store(tmp_path)
    e = FakeEmbedder(dim=64)
    for i in range(30):
        a.add_chunk(GLOBAL_NS, f"fact number {i} about things", f"f:{i}", float(i), 1.0)
    sent, lock = [], threading.Lock()

    def model(prompt, n):
        ids = [l.split("id ")[1].split(" ")[0] for l in prompt.splitlines() if l.startswith("- id ")]
        with lock:
            sent.extend(ids)
        time.sleep(0.05)
        return json.dumps([{"id": i, "kind": "fact", "importance": 5, "trivial": False, "event_start": None,
                            "event_end": None, "entities": [], "slots": "", "supersedes": []} for i in ids])
    threads = [threading.Thread(target=enrich.drain, args=(st, e), kwargs={"zone": CT, "complete": model})
               for st in (a, b)]
    [t.start() for t in threads]
    [t.join(10) for t in threads]
    assert len(sent) == 30 and len(set(sent)) == 30


# C6: near-duplicates that differ in a name, day or number are not merged
@pytest.mark.parametrize("x,y", [("Dentist appointment Tue 3pm", "Dentist appointment moved to Thu 3pm"),
                                 ("Chat with Sam about dinner plans", "Chat with Priya about dinner plans"),
                                 ("Parking is $50 a day", "Parking is $15 a day")])
def test_cleanup_keeps_near_duplicates_with_different_specifics(tmp_path, x, y):
    s = _store(tmp_path)
    e = FakeEmbedder(dim=64)
    vec = e.embed_one("same vector for both")
    for body, t in ((x, 1.0), (y, 2.0)):
        s.add_chunk(GLOBAL_NS, body, f"f:{t}", t, 1.0, embedding=vec, signature=e.signature, dim=e.dim)
    s.dequeue(s.queue_ids(10))
    cleanup.run(s, e, zone=CT, complete=lambda p, n: "[]")
    assert s.count_chunks(GLOBAL_NS) == 2


def test_write_time_merge_also_respects_specifics(tmp_path, monkeypatch):
    from plugins.memory.jarvis_memory import external
    monkeypatch.setattr(external, "_handles", {})
    monkeypatch.setattr(external, "load_config", lambda _h: {
        "embedder": "fake", "embed_dim": 64, "namespace": "global", "dedup_threshold": 0.5,
        "db_path": str(tmp_path / "m.db"), "vault_dir": str(tmp_path / "v")})
    a = external.remember("Dentist appointment Tue 3pm", source="x:1", hermes_home=str(tmp_path))
    b = external.remember("Dentist appointment Thu 3pm", source="x:2", hermes_home=str(tmp_path))
    assert a and b and a != b


# C7: where / who / when reach the role channel
def test_role_words_that_are_stopwords_still_count(tmp_path):
    from plugins.memory.jarvis_memory.recall import roles_for
    assert "venue" in roles_for("where is it?")
    assert "with" in roles_for("who is coming")
    assert "when" in roles_for("when do we leave")


# C8: one brief per namespace
def test_brief_is_per_namespace(tmp_path):
    s = _store(tmp_path)
    brief.register_source("probe", lambda ctx: f"ns={ctx.namespace}", order=99)
    brief.start(s, "user:A", interval=60, debounce=0.01)
    brief.start(s, "user:B", interval=60, debounce=0.01)
    deadline = time.time() + 3
    while not (brief.current_text("user:A") and brief.current_text("user:B")) and time.time() < deadline:
        time.sleep(0.02)
    assert "ns=user:A" in brief.current_text("user:A")
    assert "ns=user:B" in brief.current_text("user:B")


# C9: vector search while another store writes to the shared index
def test_search_while_another_connection_writes(tmp_path):
    a, b = _store(tmp_path), _store(tmp_path)
    for i in range(200):
        a.add_chunk(GLOBAL_NS, f"m{i}", f"s{i}", 1.0, 1.0, embedding=[1, i % 7, 0, 1], signature="t", dim=4)
    a.vector_search(GLOBAL_NS, [1, 0, 0, 0], "t")
    errors, stop = [], threading.Event()

    def writer():
        i = 0
        while not stop.is_set():
            cid = b.add_chunk(GLOBAL_NS, f"w{i}", f"w{i}", 1.0, 1.0, embedding=[0, 1, i % 5, 0],
                              signature="t", dim=4)
            b.delete_chunk(cid)
            i += 1

    t = threading.Thread(target=writer)
    t.start()
    try:
        end = time.time() + 1.5
        while time.time() < end:
            try:
                a.vector_search(GLOBAL_NS, [1, 0, 0, 0], "t", limit=5)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)
    finally:
        stop.set()
        t.join(5)
    assert errors == []


# C10: dates follow tense
def test_past_tense_month_day_stays_in_the_past():
    from plugins.memory.jarvis_memory.timeparse import window
    oct21 = datetime(2026, 10, 21, 20, 0, tzinfo=CT)
    assert datetime.fromtimestamp(window("what did we do on April 10", oct21).start, CT).year == 2026
    assert datetime.fromtimestamp(window("what happened on the 25th", oct21).start, CT).month == 9


# C11: entity listing without a query returns the newest
def test_entity_listing_returns_newest(tmp_path):
    from plugins.memory.jarvis_memory import JarvisMemoryProvider
    p = JarvisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path / "h"), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 64, "extract": "off",
                                   "proactive": "off", "migrate_builtin": False})
    eid = p._store.upsert_entity({"type": "person", "canonical": "Sid Patel"})
    ids = [p._store.add_chunk(GLOBAL_NS, f"Sid note {i}", f"f:{i}", float(i), 1.0) for i in range(10)]
    for cid in ids:
        p._store.link(cid, eid, "with")
    out = json.loads(p.handle_tool_call("memory_recall", {"query": "", "entity": "Sid Patel", "limit": 3}))
    assert [r["id"] for r in out["results"]] == ids[-3:]
    p.shutdown()


# C12: the map pass never hides what he saved on purpose
def test_trivial_never_hides_pinned_or_saved_memories(tmp_path):
    s = _store(tmp_path)
    e = FakeEmbedder(dim=64)
    saved = s.add_chunk(GLOBAL_NS, "I have a brother.", "tool:memory_store", 1.0, 1.0)
    pinned = s.add_chunk(GLOBAL_NS, "The user has a father.", "fact:extracted", 1.0, 1.0)
    s.set_map_fields(pinned, pinned=1)
    reply = json.dumps([{"id": i, "kind": "fact", "importance": 1, "trivial": True, "event_start": None,
                         "event_end": None, "entities": [], "slots": "", "supersedes": []} for i in (saved, pinned)])
    enrich.enrich_batch(s, e, [saved, pinned], zone=CT, complete=lambda p, n: reply)
    assert s.count_chunks(GLOBAL_NS) == 2


# C13: a failed write releases the database
def test_failed_write_does_not_hold_the_lock(tmp_path, monkeypatch):
    a, b = _store(tmp_path), _store(tmp_path)
    b._conn.execute("PRAGMA busy_timeout=500")

    def boom(*args, **kw):
        raise RuntimeError("disk hiccup")
    monkeypatch.setattr(a, "_fts_put", boom)
    with pytest.raises(RuntimeError):
        a.add_chunk(GLOBAL_NS, "x", "x", 1.0, 1.0)
    monkeypatch.undo()
    b.add_chunk(GLOBAL_NS, "y", "y", 1.0, 1.0)  # would raise "database is locked"


# C14: one entity-index rebuild per batch, not one per entity
def test_enrich_batch_rebuilds_entity_index_once(tmp_path, monkeypatch):
    s = _store(tmp_path)
    e = FakeEmbedder(dim=64)
    ids = [s.add_chunk(GLOBAL_NS, f"Met person{i} today", f"f:{i}", 1.0, 1.0) for i in range(5)]
    calls = []
    real = s.all_entities
    monkeypatch.setattr(s, "all_entities", lambda ns=None: calls.append(1) or real(ns))
    reply = json.dumps([{"id": cid, "kind": "fact", "importance": 5, "trivial": False, "event_start": None,
                         "event_end": None, "slots": "", "supersedes": [],
                         "entities": [{"name": f"Person {i} Name", "type": "person", "role": "with", "aliases": []}]}
                        for i, cid in enumerate(ids)])
    enrich.enrich_batch(s, e, ids, zone=CT, complete=lambda p, n: reply)
    assert len(calls) <= 2


def test_vague_resolver_skips_when_busy():
    from plugins.memory.jarvis_memory import vague
    gate = threading.Event()

    def slow(p, n):
        gate.wait(5)
        return "{}"
    try:
        for _ in range(4):
            vague.resolve("the venue", "x", "", "", [], complete=slow, timeout_s=0.05)
        t0 = time.perf_counter()
        assert vague.resolve("the venue", "x", "", "", [], complete=slow, timeout_s=1.0) is None
        assert time.perf_counter() - t0 < 0.2  # no slot free: skipped at once
    finally:
        gate.set()


# C15: the brief's "Now" line is fresh at read time; restamping keeps slot-augmented vectors
def test_now_line_is_current_when_read(tmp_path):
    s = _store(tmp_path)
    brief._set_text(brief.HEADER + "\nNow: Mon 1 Jan, 1:00 AM CST\nComing up (next two weeks)\n- x",
                    GLOBAL_NS)
    text = brief.current_text(GLOBAL_NS)
    assert "Mon 1 Jan, 1:00 AM" not in text and text.splitlines()[1].startswith("Now: ")
    assert "Coming up" in text


def test_restamp_keeps_slots_in_the_vector(tmp_path):
    s = _store(tmp_path)
    e = FakeEmbedder(dim=64)
    body = "Parking near COTA. (from an iMessage chat with Sid on Thu 22 Oct 2026 01:37 UTC)"
    cid = s.add_chunk(GLOBAL_NS, body, "imessage:s:1-1:f", 1.0, 1.0)
    s.set_map_fields(cid, slots="venue: Circuit of the Americas", enriched_at=1.0)
    s.dequeue([cid])
    cleanup.run(s, e, zone=CT, complete=lambda p, n: "[]")
    [c] = s.get_chunks([cid])
    want = e.embed_one(c.body + " " + c.slots)
    assert s.vector_search(GLOBAL_NS, want, e.signature, 1)[0][1] > 0.999
