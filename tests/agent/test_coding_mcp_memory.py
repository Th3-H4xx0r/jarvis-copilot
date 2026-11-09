"""The coding MCP's general-memory read follows the active profile, not ~/.jarviscopilot."""


def test_query_memory_reads_the_active_profiles_memories(tmp_path, monkeypatch):
    home = tmp_path / "profile"
    (home / "memories").mkdir(parents=True)
    (home / "memories" / "MEMORY.md").write_text("prefers tabs")
    monkeypatch.setenv("HERMES_HOME", str(home))
    from agent.coding_mcp_server import _query_memory

    assert "prefers tabs" in _query_memory()
