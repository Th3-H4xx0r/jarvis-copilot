import time

from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def _store(tmp_path):
    return MemoryStore(db_path=tmp_path / "memory.db", vault_dir=tmp_path / "vault")


def test_add_chunk_persists_row_and_vault(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk(namespace=GLOBAL_NS, body="alice shipped the auth migration",
                      source="chat:user", created_at=time.time(), score=0.7, tags="user")
    rows = s.get_chunks([cid])
    assert len(rows) == 1 and rows[0].body.startswith("alice shipped")
    assert s.count_chunks(GLOBAL_NS) == 1
    assert rows[0].content_path and (tmp_path / "vault").exists()


def test_add_chunk_idempotent(tmp_path):
    s = _store(tmp_path)
    a = s.add_chunk(GLOBAL_NS, "same body", "chat:user", time.time(), 0.5, "user")
    b = s.add_chunk(GLOBAL_NS, "same body", "chat:user", time.time(), 0.5, "user")
    assert a == b and s.count_chunks(GLOBAL_NS) == 1


def test_vector_search_orders_by_cosine(tmp_path):
    s = _store(tmp_path)
    sig = "fake:test:3"
    s.add_chunk(GLOBAL_NS, "near", "x", time.time(), 0.5, "",
                embedding=[1.0, 0.0, 0.0], signature=sig, dim=3)
    s.add_chunk(GLOBAL_NS, "far", "x", time.time(), 0.5, "",
                embedding=[0.0, 1.0, 0.0], signature=sig, dim=3)
    hits = s.vector_search(GLOBAL_NS, [1.0, 0.0, 0.0], sig, limit=2)
    assert hits[0][1] > hits[1][1]  # cosine descending
    bodies = {cid: s.get_chunks([cid])[0].body for cid, _ in hits}
    assert bodies[hits[0][0]] == "near"


def test_keyword_search_matches_any_token(tmp_path):
    s = _store(tmp_path)
    s.add_chunk(GLOBAL_NS, "the deploy script for the watch app", "x", time.time(), 0.5, "")
    s.add_chunk(GLOBAL_NS, "unrelated note about pizza", "x", time.time(), 0.5, "")
    hits = s.keyword_search(GLOBAL_NS, "how do I deploy the watch", limit=5)
    assert hits, "expected a keyword hit"
    top_body = s.get_chunks([hits[0][0]])[0].body
    assert "deploy" in top_body


def test_kv_roundtrip_and_delete(tmp_path):
    s = _store(tmp_path)
    s.kv_set(GLOBAL_NS, "editor", "prefers vim")
    assert s.kv_get(GLOBAL_NS, "editor") == "prefers vim"
    assert ("editor", "prefers vim") in s.kv_items(GLOBAL_NS)
    s.kv_delete(GLOBAL_NS, "editor")
    assert s.kv_get(GLOBAL_NS, "editor") is None


def test_delete_chunk(tmp_path):
    s = _store(tmp_path)
    cid = s.add_chunk(GLOBAL_NS, "ephemeral", "x", time.time(), 0.5, "")
    assert s.delete_chunk(cid) is True
    assert s.get_chunks([cid]) == []
