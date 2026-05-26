from __future__ import annotations
import importlib
from tools import code_memory_tool as t


def test_store_and_recall_uses_explicit_project(tmp_path, monkeypatch):
    importlib.reload(t)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    out = t.code_memory(action="store", kind="knowledge", entry_type="gotcha",
                        content="watch the off-by-one", project="proj")
    assert out.get("ok") is True
    rows = t.code_memory(action="recall", kind="knowledge", project="proj")["entries"]
    assert rows[0]["content"] == "watch the off-by-one"


def test_list_projects(tmp_path, monkeypatch):
    importlib.reload(t)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    t.code_memory(action="store", kind="sessions", entry_type="jarviscopilot",
                  content="did X", project="p2")
    t.code_memory(action="register", project="p2", name="p2", root="/r")
    assert "p2" in t.code_memory(action="list_projects")["projects"]


def test_unknown_action_errors(tmp_path, monkeypatch):
    importlib.reload(t)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    assert "error" in t.code_memory(action="bogus", project="p")
