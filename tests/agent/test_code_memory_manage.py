from __future__ import annotations
from agent import code_memory as cm


def test_count_entries(tmp_path):
    cm.write_entry("p", "knowledge", "bug", "a", home=tmp_path)
    cm.write_entry("p", "knowledge", "fix", "b", home=tmp_path)
    assert cm.count_entries("p", "knowledge", home=tmp_path) == 2
    assert cm.count_entries("p", "sessions", home=tmp_path) == 0


def test_delete_entry_removes_only_matching_ts(tmp_path, monkeypatch):
    import agent.code_memory as m
    times = iter(["2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z"])
    monkeypatch.setattr(m.time, "strftime", lambda *a, **k: next(times))
    cm.write_entry("p", "knowledge", "bug", "first", home=tmp_path)
    cm.write_entry("p", "knowledge", "fix", "second", home=tmp_path)
    removed = cm.delete_entry("p", "knowledge", "2026-01-01T00:00:00Z", home=tmp_path)
    assert removed == 1
    rows = cm.read_entries("p", "knowledge", home=tmp_path)
    assert len(rows) == 1 and rows[0]["content"] == "second"


def test_delete_entry_missing_returns_zero(tmp_path):
    cm.write_entry("p", "knowledge", "bug", "x", home=tmp_path)
    assert cm.delete_entry("p", "knowledge", "nope", home=tmp_path) == 0


def test_delete_project(tmp_path):
    cm.register_project("p", "p", "/r", "", home=tmp_path)
    cm.write_entry("p", "knowledge", "bug", "x", home=tmp_path)
    assert cm.delete_project("p", home=tmp_path) is True
    assert "p" not in cm.list_projects(home=tmp_path)
    assert not (tmp_path / "code_memory" / "p").exists()
    assert cm.delete_project("p", home=tmp_path) is False


def test_stats_aggregates(tmp_path):
    cm.register_project("a", "a", "/a", "", home=tmp_path)
    cm.write_entry("a", "knowledge", "bug", "x", home=tmp_path)
    cm.write_entry("a", "knowledge", "fix", "y", home=tmp_path)
    cm.write_entry("a", "sessions", "claude", "z", home=tmp_path)
    s = cm.stats(home=tmp_path)
    assert s["projects"] == 1 and s["knowledge"] == 2 and s["sessions"] == 1
    assert s["by_type"]["bug"] == 1 and s["by_type"]["fix"] == 1
    assert s["last_activity"]
