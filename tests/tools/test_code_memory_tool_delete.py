from __future__ import annotations
import importlib
from tools import code_memory_tool as t


def test_delete_entry_action(tmp_path, monkeypatch):
    importlib.reload(t)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    meta = t.code_memory(action="store", kind="knowledge", entry_type="bug", content="x", project="p")
    out = t.code_memory(action="delete_entry", kind="knowledge", ts=meta["ts"], project="p")
    assert out["removed"] == 1
    assert t.code_memory(action="recall", kind="knowledge", project="p")["entries"] == []


def test_delete_project_action(tmp_path, monkeypatch):
    importlib.reload(t)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    t.code_memory(action="store", kind="knowledge", entry_type="note", content="x", project="p2")
    out = t.code_memory(action="delete_project", project="p2")
    assert out["ok"] is True
    assert "p2" not in t.code_memory(action="list_projects")["projects"]
