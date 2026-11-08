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


# ── one definition, shared with the desktop's jc-client mcp-serve ─────────────

def _fake_fastmcp(monkeypatch):
    """A stand-in for mcp.server.fastmcp that records the tools offered."""
    import sys
    import types

    class FastMCP:
        def __init__(self, name):
            self.name, self.tools = name, {}

        def tool(self):
            def deco(fn):
                self.tools[fn.__name__] = fn
                return fn
            return deco

    pkg = types.ModuleType("mcp")
    server = types.ModuleType("mcp.server")
    fast = types.ModuleType("mcp.server.fastmcp")
    fast.FastMCP = FastMCP
    monkeypatch.setitem(sys.modules, "mcp", pkg)
    monkeypatch.setitem(sys.modules, "mcp.server", server)
    monkeypatch.setitem(sys.modules, "mcp.server.fastmcp", fast)


def test_server_offers_the_shared_tool_definitions(monkeypatch, temp_store):
    from agent.agent_engine_shim import load_code_assist_mcp
    shared = load_code_assist_mcp()
    _fake_fastmcp(monkeypatch)
    server = cms.build_server()
    assert server.name == "jarviscopilot-code-assist"
    assert set(server.tools) == set(shared.REQUIRED_TOOLS)  # no ask / run_skill here
    # the descriptions Claude reads are the shared ones
    assert server.tools["store_code_knowledge"].__doc__.startswith("Store ONE durable coding fact")
    assert "error" not in server.tools["store_code_knowledge"]("bug", "via the shared tool", "proj")
    assert "via the shared tool" in cms._get_code_knowledge(
        [code_memory.search("proj", "knowledge", query="shared")[0]["id"]])


def test_server_and_desktop_compute_the_same_slug():
    """Both load desktop_client/jc_client/code_memory_slug.py; if the rule forked,
    desktop and server sessions would write to different project memories."""
    from pathlib import Path
    from agent.agent_engine_shim import load_code_memory_slug
    shared = load_code_memory_slug()
    jc_file = Path(__file__).resolve().parents[1] / "desktop_client" / "jc_client" / "code_memory_slug.py"
    assert Path(shared.__file__).resolve() == jc_file
    assert code_memory.project_slug is shared.project_slug
    assert code_memory._sanitize is shared.sanitize
    assert cms.code_memory_slug is shared
