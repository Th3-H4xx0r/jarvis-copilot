"""Unit tests for the Dynamic Island design store (api.island_store).

Uses pytest tmp_path for isolation. Run from webui/:
    cd webui && python3 -m pytest tests/test_island_store.py
"""
from __future__ import annotations

from api.island_store import IslandStore, BUILTINS


def _design(did="demo", version=1):
    return {
        "id": did, "version": version, "name": did.title(),
        "presentations": {"expanded": {"type": "text", "value": "hi"}},
    }


def test_builtins_in_catalog(tmp_path):
    st = IslandStore(tmp_path)
    cat = {c["id"]: c for c in st.get_catalog()}
    for b in BUILTINS:
        assert b["id"] in cat
        assert cat[b["id"]]["builtin"] is True


def test_upsert_and_list(tmp_path):
    st = IslandStore(tmp_path)
    ok, errs = st.upsert_design(_design("deploy"))
    assert ok and errs == []
    assert "deploy" in st.list_design_ids()
    assert st.get_design("deploy")["name"] == "Deploy"
    cat = {c["id"]: c for c in st.get_catalog()}
    assert cat["deploy"]["builtin"] is False
    assert cat["deploy"]["priority"] == 10


def test_upsert_invalid_rejected(tmp_path):
    st = IslandStore(tmp_path)
    ok, errs = st.upsert_design({"id": "x", "presentations": {}})
    assert not ok and errs
    assert st.list_design_ids() == []


def test_reserved_id_rejected(tmp_path):
    st = IslandStore(tmp_path)
    ok, errs = st.upsert_design(_design("voice"))
    assert not ok
    assert any("reserved" in e for e in errs)


def test_delete_custom_and_builtin(tmp_path):
    st = IslandStore(tmp_path)
    st.upsert_design(_design("deploy"))
    assert st.delete_design("deploy") is True
    assert st.get_design("deploy") is None
    assert st.delete_design("voice") is False  # built-in not deletable


def test_selection_default_and_set(tmp_path):
    st = IslandStore(tmp_path)
    assert st.get_selection() == {"mode": "auto", "pinnedId": None}
    st.upsert_design(_design("deploy"))
    ok, _ = st.set_selection("pinned", "deploy")
    assert ok and st.get_selection() == {"mode": "pinned", "pinnedId": "deploy"}
    ok, errs = st.set_selection("pinned", "ghost")
    assert not ok and errs
    ok, _ = st.set_selection("auto", None)
    assert ok and st.get_selection()["mode"] == "auto"


def test_pin_builtin_ok(tmp_path):
    st = IslandStore(tmp_path)
    ok, _ = st.set_selection("pinned", "coding")
    assert ok and st.get_selection()["pinnedId"] == "coding"


def test_delete_pinned_falls_back_to_auto(tmp_path):
    st = IslandStore(tmp_path)
    st.upsert_design(_design("deploy"))
    st.set_selection("pinned", "deploy")
    st.delete_design("deploy")
    assert st.get_selection()["mode"] == "auto"


def test_set_rules_builtin_and_custom(tmp_path):
    st = IslandStore(tmp_path)
    ok, _ = st.set_rules("voice", enabled=False, priority=5)
    assert ok
    cat = {c["id"]: c for c in st.get_catalog()}
    assert cat["voice"]["enabled"] is False and cat["voice"]["priority"] == 5
    st.upsert_design(_design("deploy"))
    ok, _ = st.set_rules("deploy", conditions={"op": "exists", "a": {"$": "x"}})
    assert ok
    ok, errs = st.set_rules("ghost", enabled=True)
    assert not ok and any("unknown entry" in e for e in errs)


def test_set_rules_bad_condition_rejected(tmp_path):
    st = IslandStore(tmp_path)
    st.upsert_design(_design("deploy"))
    ok, errs = st.set_rules("deploy", conditions={"op": "nope"})
    assert not ok and errs


def test_data_merge_and_replace(tmp_path):
    st = IslandStore(tmp_path)
    st.upsert_design(_design("deploy"))
    st.set_data("deploy", {"a": 1, "b": 2})
    st.set_data("deploy", {"b": 3, "c": 4})  # merge
    assert st.get_data("deploy") == {"a": 1, "b": 3, "c": 4}
    st.set_data("deploy", {"only": 1}, merge=False)
    assert st.get_data("deploy") == {"only": 1}


def test_snapshot_shape(tmp_path):
    st = IslandStore(tmp_path)
    st.upsert_design(_design("deploy"))
    snap = st.snapshot()
    assert {"designs", "catalog", "selection"} <= set(snap)
    assert any(d["id"] == "deploy" for d in snap["designs"])


def test_profiles_isolated(tmp_path):
    a = IslandStore(tmp_path, "alice")
    b = IslandStore(tmp_path, "bob")
    a.upsert_design(_design("deploy"))
    assert "deploy" in a.list_design_ids()
    assert b.list_design_ids() == []
