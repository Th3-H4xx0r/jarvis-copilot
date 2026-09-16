"""The registry store: documents, records, the catalog and what it refuses."""
from __future__ import annotations

import json
import threading

import pytest

import jarvis_registry.store as store
from jarvis_registry import Registry, RegistryError, UnknownSpace
from jarvis_registry.store import MAX_DOCUMENT_BYTES, MAX_RECORD_BYTES, slug


@pytest.fixture()
def reg(tmp_path):
    r = Registry(tmp_path / "registry.db")
    yield r
    r.close()


def test_a_document_round_trips_and_overwrites(reg):
    space = reg.space("casino", name="Casino Earnings")
    space.put("settings", {"bankroll": 500}, description="Starting money")
    assert space.get("settings") == {"bankroll": 500}

    space.put("settings", {"bankroll": 420})
    assert space.get("settings") == {"bankroll": 420}
    # The description survives an overwrite that doesn't mention it.
    assert space.documents()[0]["description"] == "Starting money"
    assert space.get("missing", default={"x": 1}) == {"x": 1}


def test_records_come_back_newest_first_and_filter(reg):
    space = reg.space("casino")
    space.append("sessions", {"game": "blackjack", "net": -120}, ts=1000)
    space.append("sessions", {"game": "craps", "net": 80}, ts=2000)
    space.append("sessions", {"game": "blackjack", "net": 240}, ts=3000)

    newest = space.records("sessions")
    assert [r["ts"] for r in newest] == [3000, 2000, 1000]
    assert newest[0]["net"] == 240 and "id" in newest[0]

    assert [r["net"] for r in space.records("sessions", where={"game": "blackjack"})] == [240, -120]
    assert [r["ts"] for r in space.records("sessions", since=1500, until=2500)] == [2000]
    assert [r["ts"] for r in space.records("sessions", limit=2, newest_first=False)] == [1000, 2000]
    assert space.count("sessions") == 3


def test_the_catalog_lists_what_exists_without_the_data(reg):
    casino = reg.space("casino", name="Casino Earnings", description="Visits and earnings")
    casino.put("settings", {"bankroll": 500}, description="Starting money")
    casino.append("sessions", {"net": 10})
    casino.collection("sessions").describe("one casino visit", fields={"net": "dollars won"})
    reg.space("flights", name="Flight Tracking")

    catalog = reg.catalog()
    by_id = {c["id"]: c for c in catalog}
    assert set(by_id) == {"casino", "flights"}

    sessions = by_id["casino"]["collections"][0]
    assert sessions["name"] == "sessions"
    assert sessions["description"] == "one casino visit"
    assert sessions["fields"] == {"net": "dollars won"}
    assert sessions["count"] == 1
    assert by_id["casino"]["documents"][0]["key"] == "settings"
    # A catalog entry carries descriptions and counts, never record bodies.
    assert "bankroll" not in json.dumps(by_id["casino"])


def test_reads_never_create_a_space(reg):
    with pytest.raises(UnknownSpace):
        reg.open("nope")
    assert reg.exists("nope") is False
    assert [s["id"] for s in reg.spaces()] == []


def test_oversized_and_unserialisable_writes_are_refused(reg):
    space = reg.space("casino")
    with pytest.raises(RegistryError, match="larger than"):
        space.append("sessions", {"blob": "x" * (MAX_RECORD_BYTES + 10)})
    with pytest.raises(RegistryError, match="larger than"):
        space.put("settings", {"blob": "x" * (MAX_DOCUMENT_BYTES + 10)})
    with pytest.raises(RegistryError, match="JSON-serialisable"):
        space.put("settings", {"when": {1, 2, 3}})
    assert space.count("sessions") == 0


def test_bad_names_are_refused(reg):
    with pytest.raises(RegistryError):
        reg.space("Casino Earnings")          # spaces use slugs
    with pytest.raises(RegistryError):
        reg.space("casino", name="a" * 80)
    space = reg.space("casino")
    with pytest.raises(RegistryError):
        space.append("Sessions!", {"net": 1})
    with pytest.raises(RegistryError):
        space.put("My Key", {"a": 1})
    assert slug("Casino Earnings") == "casino-earnings"
    assert slug("  ") == "space"


def test_status_pause_and_delete(reg):
    reg.space("casino", name="Casino")
    reg.space("casino").append("sessions", {"net": 1})
    reg.set_status("casino", "paused")
    assert reg.space("casino").info()["status"] == "paused"
    with pytest.raises(RegistryError):
        reg.set_status("casino", "sleepy")

    reg.set_status("casino", "archived")
    assert [s["id"] for s in reg.spaces()] == []
    assert [s["id"] for s in reg.spaces(include_archived=True)] == ["casino"]

    assert reg.delete_space("casino") is True
    assert reg.exists("casino") is False
    # The records went with it.
    assert reg._all("SELECT * FROM records", ()) == []


def test_reopening_the_file_keeps_everything(tmp_path):
    first = Registry(tmp_path / "registry.db")
    first.space("casino", name="Casino").append("sessions", {"net": 5}, ts=10)
    first.close()

    second = Registry(tmp_path / "registry.db")
    assert second.space("casino").records("sessions")[0]["net"] == 5
    assert second.space("casino").info()["name"] == "Casino"
    second.close()


def test_two_threads_writing_lose_nothing(reg):
    reg.space("casino")

    def write(worker: int):
        space = reg.space("casino")
        for i in range(25):
            space.append("sessions", {"worker": worker, "i": i})

    threads = [threading.Thread(target=write, args=(w,)) for w in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert reg.space("casino").count("sessions") == 100
    assert len(reg.space("casino").records("sessions", where={"worker": 2}, limit=1000)) == 25


def test_a_body_may_not_hide_the_records_own_columns(reg):
    """id, ts and source are the row's; a body field of the same name would win."""
    space = reg.space("casino")
    with pytest.raises(RegistryError, match="a record may not carry ts"):
        space.append("sessions", {"ts": "2020-01-01", "net": 5})
    with pytest.raises(RegistryError, match="id, ts, source"):
        space.append("sessions", {"id": 1, "ts": 2, "source": "x"})


def test_a_bare_value_is_refused_rather_than_poisoning_the_collection(reg):
    """A list body used to read back as TypeError, for good: there is no delete."""
    space = reg.space("casino")
    with pytest.raises(RegistryError, match="must be an object"):
        space.append("sessions", [1, 2, 3])
    assert space.count("sessions") == 0


def test_a_value_json_cannot_express_is_refused(reg):
    """NaN and Infinity are not JSON; SQLite takes them, JSON.parse does not."""
    space = reg.space("casino")
    with pytest.raises(RegistryError, match="JSON-serialisable"):
        space.append("sessions", {"net": float("nan")})
    with pytest.raises(RegistryError, match="JSON-serialisable"):
        space.put("summary", {"net": float("inf")})


def test_one_query_is_bounded_by_bytes_not_only_rows(reg, monkeypatch):
    monkeypatch.setattr(store, "MAX_RESULT_BYTES", 4000)
    space = reg.space("casino")
    for _ in range(10):
        space.append("sessions", {"blob": "x" * 1000})
    rows = space.records("sessions", limit=10)
    assert 0 < len(rows) < 10


def test_a_record_can_be_taken_back_out(reg):
    space = reg.space("casino")
    record_id = space.append("sessions", {"net": 5})
    assert space.delete_record(record_id) is True
    assert space.count("sessions") == 0
    assert space.delete_record(record_id) is False


def test_an_archived_space_is_in_the_catalog_because_it_still_works(reg):
    reg.space("casino", name="Casino").append("sessions", {"net": 1})
    reg.set_status("casino", "archived")

    assert [s["id"] for s in reg.catalog(space_id="casino")] == ["casino"]
    assert reg.catalog(space_id="casino")[0]["status"] == "archived"
    # It is still writable, which is exactly why hiding it would be a lie.
    reg.open("casino").append("sessions", {"net": 2})


def test_a_collection_goes_with_its_records_and_its_catalog_entry(reg):
    space = reg.space("casino")
    for net in (10, -20, 30):
        space.append("sessions", {"net": net})
    space.collection("sessions").describe("one casino visit")
    space.append("tips", {"amount": 5})

    assert space.delete_collection("sessions") == 3
    assert [c["name"] for c in space.collections()] == ["tips"]
    assert space.records("sessions") == []
    assert space.delete_collection("sessions") == 0      # already gone
    assert space.count("tips") == 1                      # the neighbour is untouched
