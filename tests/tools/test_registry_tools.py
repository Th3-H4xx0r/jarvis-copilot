"""The agent's view of the registry: catalog, documents, records."""
from __future__ import annotations

import json

import pytest

import jarvis_registry.store as store
import tools.registry_tools as rt
from jarvis_registry import Registry


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    yield r
    r.close()


def call(handler, **args) -> dict:
    return json.loads(handler(args=args))


def test_catalog_shows_spaces_documents_and_collections(reg):
    space = reg.space("casino", name="Casino Earnings", description="Visits and earnings")
    space.put("settings", {"bankroll": 500}, description="Starting money")
    space.append("sessions", {"net": 40})
    space.collection("sessions").describe("one casino visit")

    out = call(rt._h_catalog)
    assert out["ok"] is True
    entry = out["spaces"][0]
    assert entry["id"] == "casino" and entry["name"] == "Casino Earnings"
    assert entry["documents"][0]["key"] == "settings"
    assert entry["collections"][0]["description"] == "one casino visit"
    assert entry["collections"][0]["count"] == 1

    assert call(rt._h_catalog, space="casino")["spaces"][0]["id"] == "casino"
    assert call(rt._h_catalog, space="nope")["spaces"] == []


def test_documents_and_records_round_trip(reg):
    reg.space("casino")

    assert call(rt._h_put, space="casino", key="settings", body={"bankroll": 500},
                description="Starting money")["ok"] is True
    assert call(rt._h_get, space="casino", key="settings")["body"] == {"bankroll": 500}

    first = call(rt._h_append, space="casino", collection="sessions",
                 body={"game": "blackjack", "net": -120}, ts=1000)
    assert first["ok"] is True and first["id"] > 0
    call(rt._h_append, space="casino", collection="sessions", body={"game": "craps", "net": 80},
         ts=2000)

    out = call(rt._h_query, space="casino", collection="sessions")
    assert out["count"] == 2 and out["records"][0]["net"] == 80

    filtered = call(rt._h_query, space="casino", collection="sessions",
                    where={"game": "blackjack"})
    assert [r["net"] for r in filtered["records"]] == [-120]
    assert [r["ts"] for r in call(rt._h_query, space="casino", collection="sessions",
                                  since=1500)["records"]] == [2000]


def test_describing_a_collection_reaches_the_catalog(reg):
    reg.space("casino").append("sessions", {"net": 1})
    assert call(rt._h_describe, space="casino", collection="sessions",
                description="one casino visit", fields={"net": "dollars won"})["ok"] is True
    collection = call(rt._h_catalog, space="casino")["spaces"][0]["collections"][0]
    assert collection["description"] == "one casino visit"
    assert collection["fields"] == {"net": "dollars won"}

    call(rt._h_describe, space="casino", description="Casino visits and earnings")
    assert call(rt._h_catalog, space="casino")["spaces"][0]["description"] == \
        "Casino visits and earnings"


def test_an_unknown_space_is_an_error_not_a_new_space(reg):
    out = call(rt._h_append, space="ghost", collection="sessions", body={"a": 1})
    assert out["ok"] is False and "ghost" in out["error"]
    assert call(rt._h_get, space="ghost", key="settings")["ok"] is False
    assert reg.exists("ghost") is False


def test_a_refused_write_comes_back_as_an_error(reg):
    reg.space("casino")
    out = call(rt._h_append, space="casino", collection="Sessions!", body={"a": 1})
    assert out["ok"] is False and "collection" in out["error"]

    out = call(rt._h_append, space="casino", collection="sessions",
               body={"blob": "x" * (store.MAX_RECORD_BYTES + 10)})
    assert out["ok"] is False and "larger than" in out["error"]


def test_query_limit_is_capped(reg):
    space = reg.space("casino")
    for i in range(5):
        space.append("sessions", {"i": i})
    out = call(rt._h_query, space="casino", collection="sessions", limit=10_000)
    assert out["count"] == 5  # capped, not rejected


def test_every_tool_is_registered_in_one_toolset():
    import toolsets
    from tools.registry import registry as tool_registry

    names = ["registry_catalog", "registry_get", "registry_put",
             "registry_append", "registry_query", "registry_describe",
             "integration_plan_propose", "integration_ready"]
    for name in names:
        entry = tool_registry.get_entry(name)
        assert entry is not None, f"{name} is not registered"
        assert entry.toolset == "registry"
    assert set(toolsets.TOOLSETS["registry"]["tools"]) == set(names)


def test_ready_refuses_to_declare_an_integration_that_does_not_exist(reg):
    """It is the sheet's stop signal, so it must not fire before anything is built."""
    out = call(rt._h_ready, space="gym-sessions")
    assert out["ok"] is False and "gym-sessions" in out["error"]

    reg.space("gym-sessions", name="Gym Sessions")
    out = call(rt._h_ready, space="gym-sessions", summary="Logs your workouts.")
    assert out["ok"] is True
    assert out["name"] == "Gym Sessions"
    assert out["card"] == {"kind": "integration_ready", "space": "gym-sessions"}
