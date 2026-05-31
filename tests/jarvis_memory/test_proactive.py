import time

from plugins.memory.jarvis_memory.proactive import (
    FakeReflector,
    ProactiveEngine,
    ReflectionStore,
    parse_cards,
)
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def _seed_mem(tmp_path, bodies):
    s = MemoryStore(tmp_path / "m.db", tmp_path / "v")
    for b in bodies:
        s.add_chunk(GLOBAL_NS, b, "fact:extracted", time.time(), 1.0, "fact")
    return s


def test_parse_cards():
    out = parse_cards('ok: [{"title":"A","body":"b","kind":"risk"},{"title":"B","kind":"weird"}]')
    assert out[0] == {"title": "A", "body": "b", "kind": "risk"}
    assert out[1]["kind"] == "pattern"  # unknown kind normalized
    assert parse_cards("[]") == []
    big = "[" + ",".join('{"title":"t%d"}' % i for i in range(9)) + "]"
    assert len(parse_cards(big)) == 5  # capped


def test_reflection_store_crud(tmp_path):
    s = ReflectionStore(tmp_path / "r.db")
    ids = s.add([{"title": "Card one", "body": "x", "kind": "reminder"}], ts=1.0)
    assert len(ids) == 1 and s.count("new") == 1
    assert s.list(status="new")[0]["title"] == "Card one"
    assert "card one" in s.recent_keys()
    assert s.dismiss(ids[0]) is True and s.count("new") == 0
    s.set_last_tick(42.0)
    assert s.get_last_tick() == 42.0
    s.close()


def test_engine_produces_and_stores_cards(tmp_path):
    mem = _seed_mem(tmp_path, ["the auth migration ships Friday", "Pranav lives in Mountain House"])
    rstore = ReflectionStore(tmp_path / "r.db")
    eng = ProactiveEngine(rstore, mem, FakeReflector(
        cards=[{"title": "Auth migration due Friday", "body": "Ship by Fri.", "kind": "due_item"}]))
    out = eng.tick(now_ts=9_999_999_999.0)
    assert len(out) == 1 and out[0]["kind"] == "due_item"
    assert rstore.count("new") == 1
    mem.close(); rstore.close()


def test_engine_no_new_memories_advances_and_noops(tmp_path):
    mem = _seed_mem(tmp_path, [])
    rstore = ReflectionStore(tmp_path / "r.db")
    eng = ProactiveEngine(rstore, mem, FakeReflector(cards=[{"title": "X", "kind": "pattern"}]))
    assert eng.tick(now_ts=123.0) == []
    assert rstore.get_last_tick() == 123.0
    mem.close(); rstore.close()


def test_engine_dedup_against_recent(tmp_path):
    mem = _seed_mem(tmp_path, ["the auth migration ships Friday"])
    rstore = ReflectionStore(tmp_path / "r.db")
    rstore.add([{"title": "Auth migration due Friday", "body": "x", "kind": "due_item"}], ts=1.0)
    eng = ProactiveEngine(rstore, mem, FakeReflector(
        cards=[{"title": "Auth migration due Friday", "body": "y", "kind": "due_item"}]))
    assert eng.tick(now_ts=9_999_999_999.0) == []   # deduped
    assert rstore.count() == 1
    mem.close(); rstore.close()


def test_engine_reflector_unavailable_does_not_advance(tmp_path):
    mem = _seed_mem(tmp_path, ["something new and notable to reflect on"])
    rstore = ReflectionStore(tmp_path / "r.db")
    eng = ProactiveEngine(rstore, mem, FakeReflector(raises=True))
    assert eng.tick(now_ts=5000.0) == []
    assert rstore.get_last_tick() == 0.0  # cutoff NOT advanced -> retried next tick
    mem.close(); rstore.close()


def test_max_cards_cap(tmp_path):
    mem = _seed_mem(tmp_path, ["lots happening today"])
    rstore = ReflectionStore(tmp_path / "r.db")
    many = [{"title": f"card {i}", "kind": "pattern"} for i in range(9)]
    eng = ProactiveEngine(rstore, mem, FakeReflector(cards=many))
    out = eng.tick(now_ts=9_999_999_999.0)
    assert len(out) == 5  # capped at MAX_CARDS
    mem.close(); rstore.close()
