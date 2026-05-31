import time

from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.recall import format_recall_block, hybrid_recall
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def _seed(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    e = FakeEmbedder(dim=128)
    facts = [
        "the apple watch app deploys via deploy_both.sh",
        "pranav prefers committing directly to main",
        "the favorite lunch is a burrito",
    ]
    for f in facts:
        s.add_chunk(GLOBAL_NS, f, "chat:user", time.time(), 0.7, "user",
                    embedding=e.embed_one(f), signature=e.signature, dim=e.dim)
    return s, e


def test_hybrid_recall_ranks_relevant_first(tmp_path):
    s, e = _seed(tmp_path)
    hits = hybrid_recall(s, e, "how do I deploy the watch app", GLOBAL_NS, limit=2)
    assert hits and "deploy" in hits[0].chunk.body


def test_hybrid_recall_keyword_only_fallback(tmp_path):
    s, e = _seed(tmp_path)

    class Broken(FakeEmbedder):
        def embed(self, texts):
            raise RuntimeError("embedder down")

    hits = hybrid_recall(s, Broken(dim=128), "burrito lunch", GLOBAL_NS, limit=2)
    assert hits and "burrito" in hits[0].chunk.body  # keyword arm still works


def test_format_recall_block_respects_budget(tmp_path):
    s, e = _seed(tmp_path)
    hits = hybrid_recall(s, e, "watch deploy main burrito", GLOBAL_NS, limit=3)
    assert format_recall_block([], 2000) == ""
    full = format_recall_block(hits, max_context_chars=2000)
    assert full.startswith("[Long-term memory]")
    small = format_recall_block(hits, max_context_chars=40)
    assert small.startswith("[Long-term memory]")
    assert len(small) < len(full)  # budget truncated the list
