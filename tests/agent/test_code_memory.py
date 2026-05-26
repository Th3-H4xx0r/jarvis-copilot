from __future__ import annotations
import json
from pathlib import Path
import pytest
from agent import code_memory as cm


def test_slug_from_https_remote():
    assert cm.project_slug("/x", "https://github.com/Th3-H4xx0r/jarvis-copilot.git") \
        == "github.com_th3-h4xx0r_jarvis-copilot"

def test_slug_from_ssh_remote():
    assert cm.project_slug("/x", "git@github.com:Th3-H4xx0r/jarvis-copilot.git") \
        == "github.com_th3-h4xx0r_jarvis-copilot"

def test_slug_dir_fallback_when_no_remote():
    assert cm.project_slug("/Users/me/My Project", None) == "my-project"

def test_slug_rejects_traversal():
    s = cm.project_slug("/x", "../../etc/passwd")
    assert "/" not in s and ".." not in s

def test_register_and_list(tmp_path):
    cm.register_project("github.com_a_b", "b", "/repo", "https://github.com/a/b.git", home=tmp_path)
    idx = cm.list_projects(home=tmp_path)
    assert idx["github.com_a_b"]["name"] == "b"
    assert idx["github.com_a_b"]["remote"].endswith("a/b.git")

def test_write_and_read_knowledge_newest_first(tmp_path):
    cm.write_entry("slug1", "knowledge", "bug", "null deref in foo()", home=tmp_path)
    cm.write_entry("slug1", "knowledge", "fix", "guard foo() with None check", home=tmp_path)
    rows = cm.read_entries("slug1", "knowledge", limit=10, home=tmp_path)
    assert rows[0]["entry_type"] == "fix" and "guard foo" in rows[0]["content"]
    assert rows[1]["entry_type"] == "bug"

def test_sessions_kind_separate_file(tmp_path):
    cm.write_entry("slug1", "sessions", "claude", "did X; state Y; open Z", home=tmp_path)
    assert (tmp_path / "code_memory" / "slug1" / "sessions.md").exists()
    assert not (tmp_path / "code_memory" / "slug1" / "knowledge.md").exists()

def test_read_limit_and_oversize_rejected(tmp_path):
    for i in range(60):
        cm.write_entry("s", "knowledge", "note", f"n{i}", home=tmp_path)
    assert len(cm.read_entries("s", "knowledge", limit=5, home=tmp_path)) == 5
    with pytest.raises(ValueError):
        cm.write_entry("s", "knowledge", "note", "x" * (cm.MAX_ENTRY_BYTES + 1), home=tmp_path)

def test_invalid_kind_and_entry_type(tmp_path):
    with pytest.raises(ValueError):
        cm.write_entry("s", "bogus", "note", "x", home=tmp_path)
