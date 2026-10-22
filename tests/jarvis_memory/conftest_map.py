"""Shared fixture: a small store shaped like the real "the venue" miss."""
from datetime import datetime
from zoneinfo import ZoneInfo

from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore

CT = ZoneInfo("America/Chicago")
NOW = datetime(2026, 10, 21, 20, 56, tzinfo=CT)


def ts(*args):
    return datetime(*args, tzinfo=CT).timestamp()


def build_venue_store(tmp_path):
    s = MemoryStore(tmp_path / "memory.db", tmp_path / "vault")
    e = FakeEmbedder(dim=128)
    ids = {}

    def add(key, body, created, **fields):
        ids[key] = s.add_chunk(GLOBAL_NS, body, f"test:{key}", created, 1.0, "fact",
                               embedding=e.embed_one(body), signature=e.signature, dim=e.dim)
        if fields:
            s.set_map_fields(ids[key], **fields)

    add("grad", "Arnav Bhola suggested arriving early to find a parking spot near the graduation venue.",
        ts(2026, 6, 12, 17, 37))
    add("f1_trip", "Pranav is going to the Formula 1 US Grand Prix at COTA in Austin with Sid and Sai.",
        ts(2026, 10, 20, 18, 0), event_start=ts(2026, 10, 23, 9, 0), event_end=ts(2026, 10, 25, 23, 0),
        kind="plan", importance=8,
        slots="venue: Circuit of the Americas · event: F1 US Grand Prix · with: Sid, Sai")
    add("f1_held", "US GP is held at COTA, Austin.", ts(2026, 10, 20, 18, 1),
        kind="fact", importance=5, slots="venue: Circuit of the Americas")
    add("f1_parking", "Parking near COTA is about $50 a day.", ts(2026, 10, 20, 18, 2),
        kind="fact", importance=5, slots="place: Circuit of the Americas")
    add("f1_pass", "The group decided to buy a pass for the weekend lot.", ts(2026, 10, 20, 18, 3),
        kind="plan", importance=6)
    add("junk", "The user has a father.", ts(2026, 10, 3, 12, 0), importance=1)
    add("maps", "Pranav uses Google Maps for navigation.", ts(2026, 9, 1, 12, 0), importance=4)
    add("old_home", "Pranav lives in Mountain House, California.", ts(2026, 5, 31, 12, 0),
        kind="fact", importance=6)
    add("home", "Pranav lives in Houston at 1625 Main St.", ts(2026, 10, 19, 12, 0),
        kind="fact", importance=6)
    s.set_map_fields(ids["old_home"], valid_to=ts(2026, 10, 19, 12, 0), superseded_by=ids["home"])

    f1 = s.upsert_entity({"type": "event", "canonical": "F1 US Grand Prix", "aliases": ["US GP", "the race"],
                          "event_start": ts(2026, 10, 23, 9, 0), "event_end": ts(2026, 10, 25, 23, 0)})
    cota = s.upsert_entity({"type": "place", "canonical": "Circuit of the Americas", "aliases": ["COTA"]})
    sid = s.upsert_entity({"type": "person", "canonical": "Sid Patel"})
    for k in ("f1_trip", "f1_held", "f1_parking", "f1_pass"):
        s.link(ids[k], f1, "event")
    for k in ("f1_trip", "f1_held", "f1_parking"):
        s.link(ids[k], cota, "venue")
    s.link(ids["f1_trip"], sid, "with")
    ids.update(e_f1=f1, e_cota=cota, e_sid=sid)
    return s, e, ids
