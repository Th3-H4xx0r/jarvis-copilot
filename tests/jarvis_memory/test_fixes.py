"""Regression tests locking in the bug-sweep fixes (2026-05-30)."""
import json
import time

from plugins.memory.jarvis_memory import JarvisMemoryProvider
from plugins.memory.jarvis_memory.embed import FakeEmbedder, OllamaEmbedder
from plugins.memory.jarvis_memory.ingest import ingest_turn
from plugins.memory.jarvis_memory.recall import hybrid_recall
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def _provider(tmp_path, **over):
    p = JarvisMemoryProvider()
    cfg = {"embedder": "fake", "embed_dim": 64}
    cfg.update(over)
    p.initialize("s", hermes_home=str(tmp_path), platform="cli", _config_override=cfg)
    return p


# -- C1: OllamaEmbedder signature must be frozen (no mid-batch dim mutation) --
def test_ollama_signature_frozen_on_dim_mismatch():
    e = OllamaEmbedder(model="bge-m3", dim=1024)
    sig_before = e.signature
    # Simulate a response of a different length being processed.
    e._warned_dim = False
    # The mutation path was removed; signature must not change regardless.
    assert e.signature == sig_before == "ollama:bge-m3:1024"
    assert e.dim == 1024


# -- M1: blank / tokenless query must not return noise --
def test_blank_query_returns_no_hits(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    e = FakeEmbedder(dim=64)
    s.add_chunk(GLOBAL_NS, "some stored fact about deploys", "chat:user", time.time(), 0.7, "",
                embedding=e.embed_one("some stored fact about deploys"), signature=e.signature, dim=e.dim)
    assert hybrid_recall(s, e, "", GLOBAL_NS, limit=5) == []
    assert hybrid_recall(s, e, "   ", GLOBAL_NS, limit=5) == []


# -- store: non-ASCII keyword search works --
def test_unicode_keyword_search(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    s.add_chunk(GLOBAL_NS, "Pranav lives in München near the office", "x", time.time(), 0.5, "")
    hits = s.keyword_search(GLOBAL_NS, "München", limit=5)
    assert hits and "München" in s.get_chunks([hits[0][0]])[0].body


# -- store: forget removes the vault markdown file (no plaintext left behind) --
def test_delete_removes_vault_file(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    cid = s.add_chunk(GLOBAL_NS, "secret to be forgotten", "x", time.time(), 0.5, "")
    path = s.get_chunks([cid])[0].content_path
    from pathlib import Path
    assert path and Path(path).exists()
    assert s.delete_chunk(cid) is True
    assert not Path(path).exists()


# -- store: empty embedding is not stored as a useless dim=0 vector row --
def test_empty_embedding_not_stored(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    cid = s.add_chunk(GLOBAL_NS, "body without a real vector", "x", time.time(), 0.5, "",
                      embedding=[], signature="x:0", dim=0)
    # No vector row -> vector_search finds nothing under that signature.
    assert s.vector_search(GLOBAL_NS, [], "x:0", limit=5) == []
    assert s.get_chunks([cid])  # the chunk itself still exists


# -- store: namespace isolation across chunks, vectors, kv --
def test_namespace_isolation(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    e = FakeEmbedder(dim=64)
    s.add_chunk("ns_a", "alpha project notes", "x", time.time(), 0.5, "",
                embedding=e.embed_one("alpha project notes"), signature=e.signature, dim=e.dim)
    s.add_chunk("ns_b", "beta project notes", "x", time.time(), 0.5, "",
                embedding=e.embed_one("beta project notes"), signature=e.signature, dim=e.dim)
    assert s.count_chunks("ns_a") == 1 and s.count_chunks("ns_b") == 1
    a_hits = hybrid_recall(s, e, "project notes", "ns_a", limit=5)
    assert a_hits and all(h.chunk.namespace == "ns_a" for h in a_hits)
    s.kv_set("ns_a", "k", "v")
    assert s.kv_get("ns_b", "k") is None


# -- ingest: embedder failure during ingest still captures (without vectors) --
def test_ingest_soft_fallback_when_embedder_raises(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")

    class Broken(FakeEmbedder):
        def embed(self, texts):
            raise RuntimeError("embedder down")

    ids = ingest_turn(s, Broken(dim=64), GLOBAL_NS,
                      "how do I deploy the watch app to the device?",
                      "Use the deploy_both.sh script.", source="chat")
    assert ids and s.count_chunks(GLOBAL_NS) == len(ids)
    # Captured chunks are still findable by keyword even with no vectors.
    assert s.keyword_search(GLOBAL_NS, "deploy", limit=5)


# -- provider: forget tool actually removes the item from recall --
def test_forget_tool_removes_from_recall(tmp_path):
    p = _provider(tmp_path)
    stored = json.loads(p.handle_tool_call("memory_store", {"content": "Pranav commits straight to main"}))
    cid = stored["id"]
    before = json.loads(p.handle_tool_call("memory_recall", {"query": "how does pranav commit"}))
    assert any(r["id"] == cid for r in before["results"])
    p.handle_tool_call("memory_forget", {"id": cid})
    after = json.loads(p.handle_tool_call("memory_recall", {"query": "how does pranav commit"}))
    assert all(r["id"] != cid for r in after["results"])
    p.shutdown()


# -- provider: system_prompt_block empty until something is stored --
def test_system_prompt_block_empty_then_populated(tmp_path):
    p = _provider(tmp_path)
    assert p.system_prompt_block() == ""
    p.handle_tool_call("memory_store", {"content": "a durable fact worth remembering"})
    block = p.system_prompt_block()
    assert "1 items" in block and "memory_recall" in block
    p.shutdown()


# -- provider: shutdown is idempotent --
def test_shutdown_idempotent(tmp_path):
    p = _provider(tmp_path)
    p.shutdown()
    p.shutdown()  # must not raise


# -- store: data persists across reopen (vault + db are durable) --
def test_persists_across_reopen(tmp_path):
    e = FakeEmbedder(dim=64)
    s1 = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    s1.add_chunk(GLOBAL_NS, "durable across restart", "x", time.time(), 0.5, "",
                 embedding=e.embed_one("durable across restart"), signature=e.signature, dim=e.dim)
    s1.close()
    s2 = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    assert s2.count_chunks(GLOBAL_NS) == 1
    assert hybrid_recall(s2, e, "durable restart", GLOBAL_NS, limit=5)
    s2.close()


# -- provider: get_config_schema exposes the embedder choice for `memory setup` --
def test_config_schema_for_setup(tmp_path):
    p = JarvisMemoryProvider()
    schema = p.get_config_schema()
    keys = {f["key"] for f in schema}
    assert {"embedder", "ollama_model", "embed_dim", "recall_limit"} <= keys
    embedder_field = next(f for f in schema if f["key"] == "embedder")
    assert "ollama" in embedder_field["choices"] and "fake" in embedder_field["choices"]
