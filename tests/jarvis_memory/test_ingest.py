from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.ingest import (
    DROP_THRESHOLD,
    cheap_score,
    chunk_text,
    ingest_turn,
)
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def test_cheap_score_drops_trivial_keeps_substantive():
    assert cheap_score("ok") < DROP_THRESHOLD
    assert cheap_score("we decided to migrate the auth service to oauth on friday") >= DROP_THRESHOLD


def test_chunk_text_splits_and_caps():
    pieces = chunk_text("para one\n\npara two", max_chars=1000)
    assert pieces == ["para one", "para two"]
    big = "x " * 2000
    assert all(len(p) <= 1000 for p in chunk_text(big, max_chars=1000))


def test_ingest_turn_stores_and_is_idempotent(tmp_path):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    e = FakeEmbedder(dim=64)
    ids1 = ingest_turn(s, e, GLOBAL_NS, "how do I deploy the watch app?",
                       "Run deploy_both.sh from mobile_client.", source="chat")
    assert ids1
    n1 = s.count_chunks(GLOBAL_NS)
    ids2 = ingest_turn(s, e, GLOBAL_NS, "how do I deploy the watch app?",
                       "Run deploy_both.sh from mobile_client.", source="chat")
    assert s.count_chunks(GLOBAL_NS) == n1  # idempotent, no dupes
    assert set(ids1) == set(ids2)
