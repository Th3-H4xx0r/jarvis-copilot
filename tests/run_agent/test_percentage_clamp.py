"""Tests for percentage clamping at 100% across display paths.

PR #3480 capped context pressure percentage at 100% in agent/display.py
but missed the same unclamped pattern in 4 other files. When token counts
overshoot the context length (possible during streaming or before
compression fires), users see >100% in /stats, gateway status, and
memory tool output.
"""


class TestMemoryToolPercentClamp:
    """tools/memory_tool.py — the usage shown in responses and the prompt block."""

    def _store(self, tmp_path, monkeypatch, limit):
        import tools.memory_tool as memory_tool
        monkeypatch.setattr(memory_tool, "get_memory_dir", lambda: tmp_path)
        store = memory_tool.MemoryStore(memory_char_limit=limit, user_char_limit=limit)
        store.load_from_disk()
        return store

    def test_over_limit_usage_is_clamped_at_100(self, tmp_path, monkeypatch):
        (tmp_path / "MEMORY.md").write_text("x" * 300, encoding="utf-8")
        store = self._store(tmp_path, monkeypatch, limit=200)
        assert store._success_response("memory")["usage"].startswith("100% ")
        block = store._render_block("memory", store.memory_entries)
        assert "[100% " in block

    def test_normal_usage_percentage(self, tmp_path, monkeypatch):
        store = self._store(tmp_path, monkeypatch, limit=200)
        result = store.add("memory", "y" * 100)
        assert result["usage"].startswith("50% ")


class TestSourceLinesAreClamped:
    """Verify the actual source files have min(100, ...) applied."""

    @staticmethod
    def _read_file(rel_path: str) -> str:
        import os
        base = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
        with open(os.path.join(base, rel_path)) as f:
            return f.read()

    def test_gateway_run_clamped(self):
        src = self._read_file("gateway/run.py")
        # Check that the stats handler has min(100, ...)
        assert "min(100, ctx.last_prompt_tokens" in src, (
            "gateway/run.py stats pct is not clamped with min(100, ...)"
        )

    def test_cli_clamped(self):
        src = self._read_file("cli.py")
        assert "min(100, (last_prompt" in src, (
            "cli.py /stats pct is not clamped with min(100, ...)"
        )
