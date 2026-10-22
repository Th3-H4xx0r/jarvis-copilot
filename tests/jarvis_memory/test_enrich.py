"""Batched map enrichment: dates, entities, slots, supersession, trivial."""
import json
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pytest

from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.enrich import enrich_batch
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore

CT = ZoneInfo("America/Chicago")


def _ts(*a):
    return datetime(*a, tzinfo=CT).timestamp()


@pytest.fixture
def env(tmp_path):
    s = MemoryStore(tmp_path / "memory.db", tmp_path / "vault")
    e = FakeEmbedder(dim=64)

    def add(body, when, source="imessage:c1:1-2:f"):
        return s.add_chunk(GLOBAL_NS, body, source, when, 1.0, "fact",
                           embedding=e.embed_one(body), signature=e.signature, dim=e.dim)
    return s, e, add


class Model:
    def __init__(self, reply):
        self.reply, self.prompts = reply, []

    def __call__(self, prompt, max_tokens=1500):
        self.prompts.append(prompt)
        return self.reply(prompt) if callable(self.reply) else self.reply


def test_relative_date_resolved_in_local_zone(env):
    s, e, add = env
    cid = add("We leave tomorrow at 7am for COTA", _ts(2026, 10, 23, 22, 30))
    model = Model(lambda p: json.dumps([{"id": cid, "kind": "plan", "importance": 7, "trivial": False,
                                         "event_start": "2026-10-24T07:00", "event_end": None,
                                         "entities": [], "slots": "when: Sat 24 Oct 7:00", "supersedes": []}]))
    enrich_batch(s, e, [cid], zone=CT, complete=model)
    assert "Fri 23 Oct 2026 22:30" in model.prompts[0]
    [c] = s.get_chunks([cid])
    assert c.event_start == _ts(2026, 10, 24, 7, 0)
    assert c.kind == "plan" and c.importance == 7 and c.slots.startswith("when:")
    assert s.queue_ids(10) == []


def test_entities_linked_and_aliases_indexed(env):
    s, e, add = env
    cid = add("Parking near COTA is about $50 a day", _ts(2026, 10, 20, 12, 0))
    model = Model(lambda p: json.dumps([{"id": cid, "kind": "fact", "importance": 5, "trivial": False,
        "event_start": None, "event_end": None, "slots": "place: Circuit of the Americas · price: $50/day",
        "supersedes": [],
        "entities": [{"name": "Circuit of the Americas", "type": "place", "role": "place", "aliases": ["COTA"]},
                     {"name": "F1 US Grand Prix", "type": "event", "role": "event", "aliases": ["US GP"]}]}]))
    enrich_batch(s, e, [cid], zone=CT, complete=model)
    links = dict((s.get_entities([eid])[eid]["canonical"], role) for eid, role in s.entities_for([cid])[cid])
    assert links == {"Circuit of the Americas": "place", "F1 US Grand Prix": "event"}
    from plugins.memory.jarvis_memory.entities import EntityIndex
    assert EntityIndex(s, GLOBAL_NS).match("is COTA far")
    assert [c for c, _ in s.keyword_search(GLOBAL_NS, "price")] == [cid]


def test_existing_entity_reused_by_first_name(env):
    s, e, add = env
    arnav = s.upsert_entity({"type": "person", "canonical": "Arnav Bhola"})
    cid = add("Arnav is bringing snacks", _ts(2026, 10, 20, 12, 0))
    model = Model(lambda p: json.dumps([{"id": cid, "kind": "plan", "importance": 4, "trivial": False,
        "event_start": None, "event_end": None, "slots": "with: Arnav", "supersedes": [],
        "entities": [{"name": "Arnav", "type": "person", "role": "with", "aliases": []}]}]))
    enrich_batch(s, e, [cid], zone=CT, complete=model)
    assert s.entities_for([cid])[cid] == [(arnav, "with")]
    assert len([x for x in s.all_entities(GLOBAL_NS) if x["type"] == "person"]) == 1


def test_supersedes_marks_old_past(env):
    s, e, add = env
    old = add("Pranav lives in Mountain House, California", _ts(2026, 5, 31, 12, 0))
    s.dequeue([old])
    new = add("Pranav lives in Houston now", _ts(2026, 10, 19, 12, 0))
    model = Model(lambda p: json.dumps([{"id": new, "kind": "fact", "importance": 6, "trivial": False,
        "event_start": None, "event_end": None, "slots": "place: Houston", "entities": [],
        "supersedes": [old]}]))
    enrich_batch(s, e, [new], zone=CT, complete=model)
    [o] = s.get_chunks([old])
    assert o.valid_to == _ts(2026, 10, 19, 12, 0) and o.superseded_by == new
    assert old in model.prompts[0]  # offered as a related memory


def test_supersedes_ignores_ids_not_offered(env):
    s, e, add = env
    other = add("Unrelated memory about lunch", _ts(2026, 1, 1, 12, 0))
    s.dequeue([other])
    new = add("Pranav moved to Houston", _ts(2026, 10, 19, 12, 0))
    model = Model(lambda p: json.dumps([{"id": new, "kind": "fact", "importance": 6, "trivial": False,
        "event_start": None, "event_end": None, "slots": "", "entities": [], "supersedes": ["c_made_up"]}]))
    enrich_batch(s, e, [new], zone=CT, complete=model)
    assert s.get_chunks([other])[0].valid_to is None


def test_trivial_hidden_not_deleted(env):
    s, e, add = env
    cid = add("The user has a father.", _ts(2026, 10, 3, 12, 0))
    model = Model(lambda p: json.dumps([{"id": cid, "kind": "fact", "importance": 1, "trivial": True,
        "event_start": None, "event_end": None, "slots": "", "entities": [], "supersedes": []}]))
    enrich_batch(s, e, [cid], zone=CT, complete=model)
    assert s.count_chunks(GLOBAL_NS) == 0
    row = s._conn.execute("SELECT status FROM chunks WHERE id=?", (cid,)).fetchone()
    assert row["status"] == "hidden"


def test_malformed_json_keeps_queue_then_gives_up(env):
    s, e, add = env
    cid = add("something", _ts(2026, 10, 3, 12, 0))
    for _ in range(3):
        enrich_batch(s, e, [cid], zone=CT, complete=Model("not json at all"))
    assert s.queue_ids(10) == []
    assert s.get_chunks([cid])[0].body == "something"


def test_model_error_does_not_burn_attempts(env):
    s, e, add = env
    cid = add("something", _ts(2026, 10, 3, 12, 0))

    def down(prompt, max_tokens=1500):
        raise RuntimeError("provider down")
    for _ in range(5):
        enrich_batch(s, e, [cid], zone=CT, complete=down)
    assert s.queue_ids(10) == [cid]


def test_reembeds_with_slots(env):
    s, e, add = env
    cid = add("Pranav is going to the race", _ts(2026, 10, 20, 12, 0))
    model = Model(lambda p: json.dumps([{"id": cid, "kind": "plan", "importance": 7, "trivial": False,
        "event_start": None, "event_end": None, "slots": "venue: Circuit of the Americas",
        "entities": [], "supersedes": []}]))
    enrich_batch(s, e, [cid], zone=CT, complete=model)
    want = np.asarray(e.embed_one("Pranav is going to the race venue: Circuit of the Americas"))
    got = s.vector_search(GLOBAL_NS, want.tolist(), e.signature, 1)
    assert got[0][0] == cid and got[0][1] > 0.999


def test_a_cut_off_reply_keeps_its_complete_items(env):
    s, e, add = env
    a = add("Sid is driving to Austin", _ts(2026, 10, 20, 12, 0))
    b = add("Parking is $50 a day", _ts(2026, 10, 20, 12, 1))
    item = {"id": a, "kind": "plan", "importance": 6, "trivial": False, "event_start": None,
            "event_end": None, "entities": [], "slots": "with: Sid", "supersedes": []}
    cut = "```json\n[\n  " + json.dumps(item, indent=2) + ',\n  {\n    "id": "' + b + '",\n    "kind": "fa'
    counts = enrich_batch(s, e, [a, b], zone=CT, complete=Model(cut))
    assert counts["enriched"] == 1 and counts["failed"] == 1
    assert s.get_chunks([a])[0].slots == "with: Sid"
    assert s.queue_ids(10) == [b]
