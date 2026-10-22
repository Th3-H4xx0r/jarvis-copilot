"""In-memory vector index + stopword-free, strength-scored keyword search."""
import numpy as np

from plugins.memory.jarvis_memory.store import MemoryStore
from plugins.memory.jarvis_memory.textq import fts_query


def _store(tmp_path):
    return MemoryStore(tmp_path / "memory.db", tmp_path / "vault")


def test_index_matches_bruteforce_cosine(tmp_path):
    rng = np.random.default_rng(7)
    s = _store(tmp_path)
    vecs = {}
    for i in range(100):
        v = rng.normal(size=16).astype(np.float32)
        cid = s.add_chunk("global", f"memory number {i}", f"src{i}", float(i), 1.0,
                          embedding=v.tolist(), signature="t", dim=16)
        vecs[cid] = v
    q = rng.normal(size=16).astype(np.float32)
    brute = sorted(((cid, float(v @ q / (np.linalg.norm(v) * np.linalg.norm(q))))
                    for cid, v in vecs.items()), key=lambda x: -x[1])[:5]
    got = s.vector_search("global", q.tolist(), "t", limit=5)
    assert [c for c, _ in got] == [c for c, _ in brute]
    for (_, a), (_, b) in zip(got, brute):
        assert abs(a - b) < 1e-5


def test_index_sees_writes_and_hides(tmp_path):
    s = _store(tmp_path)
    a = s.add_chunk("global", "a", "a", 1.0, 1.0, embedding=[1, 0, 0, 0], signature="t", dim=4)
    assert [c for c, _ in s.vector_search("global", [1, 0, 0, 0], "t")] == [a]
    b = s.add_chunk("global", "b", "b", 1.0, 1.0, embedding=[0.9, 0.1, 0, 0], signature="t", dim=4)
    assert [c for c, _ in s.vector_search("global", [1, 0, 0, 0], "t")] == [a, b]
    s.set_status([a], "hidden")
    assert [c for c, _ in s.vector_search("global", [1, 0, 0, 0], "t")] == [b]
    s.set_status([a], "active")
    s.delete_chunk(b)
    assert [c for c, _ in s.vector_search("global", [1, 0, 0, 0], "t")] == [a]
    s.update_body(a, "a2", embedding=[0, 1, 0, 0], signature="t", dim=4)
    assert s.vector_search("global", [0, 1, 0, 0], "t")[0][1] > 0.99
    assert s.vector_search("global", [1, 0, 0, 0], "t", only_ids={"nope"}) == []


def test_stopword_only_query_has_no_keyword_hits(tmp_path):
    s = _store(tmp_path)
    s.add_chunk("global", "can you open the door for the dog", "a", 1.0, 1.0)
    assert fts_query("can you open the") == ""
    assert s.keyword_search("global", "can you open the") == []


def test_fts_query_keeps_content_words():
    assert fts_query("Can you open navigation to the venue?") == '"navigation" OR "venue"'


def test_keyword_score_reflects_strength(tmp_path):
    s = _store(tmp_path)
    strong = s.add_chunk("global", "the race venue: the venue for the F1 race is COTA", "a", 1.0, 1.0)
    weak = s.add_chunk("global", "we watched a race on tv", "b", 2.0, 1.0)
    hits = dict(s.keyword_search("global", "the race venue"))
    assert hits[strong] > hits[weak]
    assert all(0.0 < v < 1.0 for v in hits.values())
