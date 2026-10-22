"""Entity alias index: names in a question → people, places, events."""
from plugins.memory.jarvis_memory.entities import EntityIndex
from plugins.memory.jarvis_memory.store import MemoryStore


def _setup(tmp_path):
    s = MemoryStore(tmp_path / "memory.db", tmp_path / "vault")
    ids = {
        "cota": s.upsert_entity({"type": "place", "canonical": "Circuit of the Americas",
                                 "aliases": ["COTA"]}),
        "arnav": s.upsert_entity({"type": "person", "canonical": "Arnav Bhola"}),
        "sai1": s.upsert_entity({"type": "person", "canonical": "Sai Kumar"}),
        "sai2": s.upsert_entity({"type": "person", "canonical": "Sai Reddy"}),
        "f1": s.upsert_entity({"type": "event", "canonical": "F1 US Grand Prix",
                               "aliases": ["US GP"]}),
    }
    return s, EntityIndex(s, "global"), ids


def test_matches_alias_cota(tmp_path):
    _, idx, ids = _setup(tmp_path)
    assert [m[0] for m in idx.match("are we going to COTA early?")] == [ids["cota"]]


def test_matches_full_name_and_multiword(tmp_path):
    _, idx, ids = _setup(tmp_path)
    got = {m[0] for m in idx.match("did Arnav Bhola say anything about the F1 US Grand Prix")}
    assert got == {ids["arnav"], ids["f1"]}


def test_first_name_resolves_to_unique_person(tmp_path):
    _, idx, ids = _setup(tmp_path)
    assert idx.resolve("Arnav", "person") == ids["arnav"]
    assert [m[0] for m in idx.match("what did arnav say")] == [ids["arnav"]]


def test_ambiguous_first_name_unresolved(tmp_path):
    _, idx, _ = _setup(tmp_path)
    assert idx.resolve("Sai", "person") is None
    assert idx.match("text sai") == []


def test_role_word_not_an_entity(tmp_path):
    _, idx, _ = _setup(tmp_path)
    assert idx.match("open navigation to the venue") == []


def test_refresh_sees_new_entities(tmp_path):
    s, idx, _ = _setup(tmp_path)
    assert idx.match("dinner at Uchi") == []
    uchi = s.upsert_entity({"type": "place", "canonical": "Uchi Houston", "aliases": ["Uchi"]})
    assert [m[0] for m in idx.match("dinner at Uchi")] == [uchi]
