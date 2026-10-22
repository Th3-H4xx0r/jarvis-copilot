"""Map schema on the memory store: migration, hidden status, multi-source memories."""
import sqlite3
from pathlib import Path

from plugins.memory.jarvis_memory.store import MemoryStore


def _store(tmp_path):
    return MemoryStore(tmp_path / "memory.db", tmp_path / "vault")


def _vec(*xs):
    return list(xs) + [0.0] * (4 - len(xs))


def test_migrates_old_db_in_place(tmp_path):
    db = tmp_path / "memory.db"
    conn = sqlite3.connect(db)
    conn.executescript(
        """
        CREATE TABLE chunks(id TEXT PRIMARY KEY, namespace TEXT NOT NULL, body TEXT NOT NULL,
          content_path TEXT, content_sha256 TEXT, source TEXT, created_at REAL NOT NULL,
          score REAL DEFAULT 0, tags TEXT DEFAULT '');
        INSERT INTO chunks(id,namespace,body,source,created_at,score,tags)
          VALUES ('c_old','global','Pranav lives in Houston','fact:extracted',1.0,1.0,'fact');
        """
    )
    conn.commit()
    conn.close()
    s = MemoryStore(db, tmp_path / "vault")
    cols = {r[1] for r in s._conn.execute("PRAGMA table_info(chunks)")}
    assert {"status", "event_start", "event_end", "valid_to", "superseded_by", "importance",
            "kind", "pinned", "slots", "source_ref", "enriched_at", "stored_at"} <= cols
    [chunk] = s.get_chunks(["c_old"])
    assert chunk.status == "active"
    srcs = [r[0] for r in s._conn.execute("SELECT source FROM memory_sources WHERE memory_id='c_old'")]
    assert srcs == ["fact:extracted"]


def test_forget_one_of_two_sources_keeps_memory(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "Parking near COTA is about $50 a day", "imessage:chatA:f",
                      1.0, 1.0, "imessage,fact")
    s.merge_source(cid, "imessage:chatB:f")
    assert s.forget_source(source_prefix="imessage:chatA:") == 0
    [chunk] = s.get_chunks([cid])
    assert chunk.body.startswith("Parking near COTA")
    srcs = [r[0] for r in s._conn.execute("SELECT source FROM memory_sources WHERE memory_id=?", (cid,))]
    assert srcs == ["imessage:chatB:f"]


def test_forget_last_source_deletes_and_unlinks_vault(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "Parking near COTA is about $50 a day", "imessage:chatA:f",
                      1.0, 1.0, "imessage,fact")
    s.merge_source(cid, "imessage:chatB:f")
    path = Path(s._conn.execute("SELECT content_path FROM chunks WHERE id=?", (cid,)).fetchone()[0])
    assert path.exists()
    s.forget_source(source_prefix="imessage:chatA:")
    assert s.forget_source(source_prefix="imessage:chatB:") == 1
    assert s.get_chunks([cid]) == []
    assert not path.exists()


def test_forget_by_tag_unlinks_tagged_source(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "Brenda teaches the Tuesday lesson", "live:s1:0-4",
                      1.0, 1.0, "live,conversation,speaker:v1")
    assert s.forget_source(tag="speaker:v1") == 1
    assert s.get_chunks([cid]) == []


def test_hidden_rows_excluded_everywhere(tmp_path):
    s = _store(tmp_path)
    keep = s.add_chunk("global", "the race venue is COTA", "a", 2.0, 1.0,
                       embedding=_vec(1, 0), signature="t", dim=4)
    hide = s.add_chunk("global", "the race venue was a graduation hall", "b", 1.0, 1.0,
                       embedding=_vec(1, 0.1), signature="t", dim=4)
    s.set_status([hide], "hidden")
    assert [c for c, _ in s.keyword_search("global", "race venue")] == [keep]
    assert [c for c, _ in s.vector_search("global", _vec(1, 0), "t")] == [keep]
    assert s.filtered_ids("global") == [keep]
    assert [c.id for c in s.recent_chunks("global")] == [keep]
    assert s.count_chunks("global") == 1
    assert s.namespaces() == [("global", 1)]


def test_update_body_keeps_id_and_reindexes_fts(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "Live conversation\n[10:00:01] A: hello there", "live:x", 1.0, 1.0)
    s.update_body(cid, "Live conversation\nSummary: they planned the trip")
    [chunk] = s.get_chunks([cid])
    assert "planned the trip" in chunk.body
    assert [c for c, _ in s.keyword_search("global", "planned trip")] == [cid]
    assert s.keyword_search("global", "hello") == []


def test_slots_are_searchable(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "Pranav is going to the F1 race with Sid", "f", 1.0, 1.0)
    s.set_map_fields(cid, slots="venue: Circuit of the Americas · event: F1 US Grand Prix")
    assert [c for c, _ in s.keyword_search("global", "venue")] == [cid]


def test_add_chunk_queues_for_map(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "a fact", "f", 1.0, 1.0)
    assert s.queue_ids(10) == [cid]
    s.dequeue([cid])
    assert s.queue_ids(10) == []


def test_entities_link_and_lookup(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk("global", "Pranav is going to the F1 race", "f", 1.0, 1.0)
    v0 = s.entity_version()
    eid = s.upsert_entity({"namespace": "global", "type": "event", "canonical": "F1 US Grand Prix",
                           "aliases": ["US GP"], "event_start": 10.0, "event_end": 20.0})
    assert s.entity_version() > v0
    s.link(cid, eid, "event")
    assert s.entities_for([cid]) == {cid: [(eid, "event")]}
    assert s.memories_for_entities([eid], 10) == [cid]
    [ent] = s.all_entities("global")
    assert ent["canonical"] == "F1 US Grand Prix" and ent["aliases"] == ["US GP"]
    # Upserting the same canonical name+type updates, doesn't duplicate.
    again = s.upsert_entity({"namespace": "global", "type": "event", "canonical": "F1 US Grand Prix",
                             "aliases": ["COTA race"]})
    assert again == eid
    assert set(s.all_entities("global")[0]["aliases"]) == {"US GP", "COTA race"}
