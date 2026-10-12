"""The always-loaded device tools are picked from real use, under a token
budget, plus pins — never a hardcoded list (the rest stay on demand)."""
import json
import sqlite3
import time

import pytest

from tools import device_tool_rank as r


@pytest.fixture
def cfg(monkeypatch):
    box = {"always_loaded_tokens": 0, "pinned": []}
    monkeypatch.setattr(r, "_config", lambda: dict(box))
    return box


def test_budget_fills_by_usage_then_sorts(monkeypatch, cfg):
    cfg["always_loaded_tokens"] = 250
    monkeypatch.setattr(r, "usage_counts", lambda days=30: {"device_b": 50, "device_a": 40, "device_c": 1})
    out = r.always_loaded_device_tools({"device_a": 100, "device_b": 100, "device_c": 100})
    assert out == ["device_a", "device_b"]


def test_a_big_tool_does_not_stop_smaller_ones_fitting(monkeypatch, cfg):
    cfg["always_loaded_tokens"] = 150
    monkeypatch.setattr(r, "usage_counts", lambda days=30: {"device_big": 9, "device_small": 1})
    assert r.always_loaded_device_tools({"device_big": 500, "device_small": 100}) == ["device_small"]


def test_pins_always_included(monkeypatch, cfg):
    cfg["pinned"] = ["device_z"]
    monkeypatch.setattr(r, "usage_counts", lambda days=30: {})
    assert r.always_loaded_device_tools({"device_z": 999, "device_y": 1}) == ["device_z"]


def test_pins_for_tools_that_do_not_exist_are_ignored(monkeypatch, cfg):
    cfg["pinned"] = ["device_gone"]
    monkeypatch.setattr(r, "usage_counts", lambda days=30: {})
    assert r.always_loaded_device_tools({"device_y": 1}) == []


def test_no_history_fills_in_name_order_within_budget(monkeypatch, cfg):
    cfg["always_loaded_tokens"] = 150
    monkeypatch.setattr(r, "usage_counts", lambda days=30: {})
    assert r.always_loaded_device_tools({"device_b": 100, "device_a": 100}) == ["device_a"]


def _db(path, rows):
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,"
                " tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL)")
    con.executemany("INSERT INTO messages (session_id, role, tool_calls, tool_name, timestamp) VALUES (?,?,?,?,?)", rows)
    con.commit()
    con.close()


def test_usage_counts_include_bridged_calls_and_skip_old_rows(tmp_path):
    now = time.time()
    bridged = json.dumps([{"function": {"name": "tool_call",
                                        "arguments": json.dumps({"name": "device_read_contacts", "arguments": {}})}}])
    _db(tmp_path / "state.db", [
        ("s", "tool", None, "device_open_app", now),
        ("s", "tool", None, "device_open_app", now - 40 * 86400),  # too old
        ("s", "assistant", bridged, None, now),
        ("s", "tool", None, "tool_call", now),  # the bridge's own row is not a device tool
    ])
    c = r.count_usage(tmp_path / "state.db", days=30)
    assert c["device_open_app"] == 1
    assert c["device_read_contacts"] == 1
    assert "tool_call" not in c


def test_usage_counts_read_the_daily_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(r, "_cache_path", lambda: tmp_path / "rank.json")
    (tmp_path / "rank.json").write_text(json.dumps({"computed_at": time.time(), "counts": {"device_x": 3}}))
    monkeypatch.setattr(r, "refresh_in_background", lambda: pytest.fail("a fresh cache must not recount"))
    assert r.usage_counts()["device_x"] == 3


def test_a_stale_or_missing_cache_never_blocks(tmp_path, monkeypatch):
    monkeypatch.setattr(r, "_cache_path", lambda: tmp_path / "rank.json")
    kicked = []
    monkeypatch.setattr(r, "refresh_in_background", lambda: kicked.append(1))
    assert r.usage_counts() == {}
    assert kicked == [1]


def test_bare_bridged_names_count_toward_the_device_tool(monkeypatch, cfg):
    """The bridge takes "x5_get_status" for device_x5_get_status; its calls rank it."""
    cfg["always_loaded_tokens"] = 100
    monkeypatch.setattr(r, "usage_counts", lambda days=30: {"x5_get_status": 9, "device_open_app": 2})
    assert r.always_loaded_device_tools({"device_x5_get_status": 100, "device_open_app": 100}) == [
        "device_x5_get_status"]


def test_a_failed_recount_is_not_retried_on_every_agent_build(tmp_path, monkeypatch):
    monkeypatch.setattr(r, "_cache_path", lambda: tmp_path / "rank.json")
    monkeypatch.setattr(r, "_home", lambda: tmp_path)
    (tmp_path / "state.db").write_text("not a database")
    r._recount()
    data = json.loads((tmp_path / "rank.json").read_text())
    assert data["counts"] == {} and data.get("failed")
    kicked = []
    monkeypatch.setattr(r, "refresh_in_background", lambda: kicked.append(1))
    r.usage_counts()
    assert kicked == []  # backed off; tried again later, not now
