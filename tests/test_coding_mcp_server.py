"""Unit tests for the SERVER-side code-assist MCP tool functions.

These exercise the plain tool implementations (no FastMCP / stdio) against a
temp code-memory store, so they verify the local-store integration that replaces
the desktop's ``jc-client mcp-serve`` for server-host sessions.
"""
import pytest

from agent import code_memory, code_memory_index
from agent import coding_mcp_server as cms


@pytest.fixture()
def temp_store(tmp_path, monkeypatch):
    # Route the local code-memory store at a temp dir, and force the markdown
    # path (no SQLite index) so search/get resolve against the same temp store.
    monkeypatch.setattr(code_memory, "_home", lambda home=None: tmp_path)

    def _no_index(*a, **k):
        raise RuntimeError("index disabled for test")

    monkeypatch.setattr(code_memory_index, "search", _no_index)
    monkeypatch.setattr(code_memory_index, "get_by_ids", _no_index)
    return tmp_path


def test_store_recall_get_delete_knowledge(temp_store):
    res = cms._store_code_knowledge("bug", "off-by-one in the pager", project="proj")
    assert "error" not in res

    compact = cms._recall_code_knowledge(project="proj", query="pager")
    assert "proj::knowledge" in compact  # a real id row, not "(no matching...)"

    rows = code_memory.search("proj", "knowledge", query="pager")
    eid = rows[0]["id"]
    full = cms._get_code_knowledge([eid])
    assert "off-by-one in the pager" in full

    d = cms._delete_code_memory(eid)
    assert d["deleted"] is True
    assert cms._get_code_knowledge([eid]) == "(no entries for those ids)"


def test_session_handoff_roundtrip(temp_store):
    assert "error" not in cms._store_session_handoff("did X, next Y", project="proj")
    out = cms._recall_session_handoff(project="proj", limit=3)
    assert "did X, next Y" in out


def test_recall_empty_is_friendly(temp_store):
    assert cms._recall_code_knowledge(project="empty", query="") == "(no matching knowledge yet)"
    assert cms._recall_session_handoff(project="empty") == "(no prior sessions)"


def test_bad_entry_type_returns_error_not_raise(temp_store):
    res = cms._store_code_knowledge("not_a_type", "x", project="proj")
    assert "error" in res  # write_entry rejects the entry_type; we surface it


def test_query_memory_reads_local_files(tmp_path, monkeypatch):
    mem_dir = tmp_path / ".jarviscopilot" / "memories"
    mem_dir.mkdir(parents=True)
    (mem_dir / "MEMORY.md").write_text("# Memory\nalpha fact\n", encoding="utf-8")
    (mem_dir / "USER.md").write_text("user is Pranav\n", encoding="utf-8")
    monkeypatch.setattr(cms.os.path, "expanduser", lambda p: str(tmp_path) if p == "~" else p)
    out = cms._query_memory("alpha")
    assert "alpha fact" in out
