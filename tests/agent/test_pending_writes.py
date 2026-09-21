"""Cross-session writes can be held for review instead of committed.

``agent/background_review.py`` forks the agent after a turn and, in its own
words, "writes go straight to the memory + skill stores". Over months that is
how a memory file fills with entries nobody agreed to. These tests pin the
property that makes review real: while ``memory.write_approval`` is on, a
staged write is NOT in the store until it is applied.
"""

import json

import pytest

from agent import pending_writes as pw
from tools.memory_tool import MemoryStore, memory_tool


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


@pytest.fixture
def approval_on(home):
    (home / "config.yaml").write_text("memory:\n  write_approval: true\n")
    return home


def _store():
    store = MemoryStore()
    store.load_from_disk()
    return store


class TestGateIsOffByDefault:
    def test_default_is_off(self, home):
        assert pw.write_approval_enabled("memory") is False

    def test_writes_commit_normally_when_off(self, home):
        out = json.loads(memory_tool("add", target="user",
                                     content="Committed directly", store=_store()))
        assert "staged" not in out
        assert "Committed directly" in " ".join(_store().user_entries)

    def test_unreadable_config_fails_open(self, home, monkeypatch):
        """A config we cannot read must not silently swallow writes."""
        def boom(*_a, **_k):
            raise OSError("boom")
        monkeypatch.setattr("jarviscopilot_cli.config.load_config", boom)
        assert pw.write_approval_enabled("memory") is False


class TestStagedWritesDoNotLand:
    def test_add_is_staged_not_saved(self, approval_on):
        out = json.loads(memory_tool("add", target="user",
                                     content="Prefers dark mode", store=_store()))
        assert out["staged"]
        assert "Prefers dark mode" not in " ".join(_store().user_entries)

    def test_the_agent_is_told_it_is_not_saved(self, approval_on):
        out = json.loads(memory_tool("add", target="memory",
                                     content="x", store=_store()))
        assert "NOT saved" in out["message"]

    @pytest.mark.parametrize("action,kwargs", [
        ("add", {"content": "new"}),
        ("replace", {"old_text": "a", "content": "b"}),
        ("remove", {"old_text": "a"}),
    ])
    def test_every_mutating_action_is_staged(self, approval_on, action, kwargs):
        out = json.loads(memory_tool(action, target="memory", store=_store(), **kwargs))
        assert out.get("staged"), f"{action} was not staged"

    def test_origin_records_the_background_review(self, approval_on, monkeypatch):
        """Knowing which writes you never saw happen is the point."""
        monkeypatch.setenv("HERMES_BACKGROUND_REVIEW", "1")
        memory_tool("add", target="memory", content="x", store=_store())
        assert pw.list_pending()[0]["origin"] == "background_review"

    def test_origin_records_a_foreground_turn(self, approval_on, monkeypatch):
        monkeypatch.delenv("HERMES_BACKGROUND_REVIEW", raising=False)
        memory_tool("add", target="memory", content="x", store=_store())
        assert pw.list_pending()[0]["origin"] == "turn"


class TestApplyAndDiscard:
    def test_apply_lands_the_write_and_clears_it(self, approval_on):
        memory_tool("add", target="user", content="Prefers dark mode", store=_store())
        record_id = pw.list_pending()[0]["id"]

        assert pw.apply(record_id)["success"] is True
        assert "Prefers dark mode" in " ".join(_store().user_entries)
        assert pw.list_pending() == []

    def test_discard_drops_it_without_writing(self, approval_on):
        memory_tool("add", target="user", content="Never wanted this", store=_store())
        record_id = pw.list_pending()[0]["id"]

        assert pw.discard(record_id) is True
        assert pw.list_pending() == []
        assert "Never wanted this" not in " ".join(_store().user_entries)

    def test_apply_targets_the_right_file(self, approval_on):
        memory_tool("add", target="user", content="User fact", store=_store())
        memory_tool("add", target="memory", content="Project fact", store=_store())
        for record in pw.list_pending():
            pw.apply(record["id"])
        store = _store()
        assert "User fact" in " ".join(store.user_entries)
        assert "Project fact" in " ".join(store.memory_entries)

    def test_applying_an_unknown_id_is_an_error(self, home):
        assert pw.apply("nope")["success"] is False

    def test_discarding_an_unknown_id_is_false(self, home):
        assert pw.discard("nope") is False

    def test_skills_are_not_applyable_yet(self, home):
        record = pw.stage("skills", action="add", content="x")
        result = pw.apply(record["id"])
        assert result["success"] is False
        assert "not supported" in result["error"]


class TestListing:
    def test_empty_when_nothing_staged(self, home):
        assert pw.list_pending() == []

    def test_oldest_first(self, home):
        first = pw.stage("memory", action="add", content="one")
        second = pw.stage("memory", action="add", content="two")
        ids = [r["id"] for r in pw.list_pending()]
        assert ids.index(first["id"]) < ids.index(second["id"])

    def test_kind_filter(self, home):
        pw.stage("memory", action="add", content="m")
        pw.stage("skills", action="add", content="s")
        assert len(pw.list_pending("memory")) == 1
        assert len(pw.list_pending()) == 2

    def test_a_corrupt_record_does_not_break_the_listing(self, home):
        pw.stage("memory", action="add", content="good")
        (pw.pending_dir("memory") / "broken.json").write_text("{not json")
        records = pw.list_pending()
        assert len(records) == 1
        assert records[0]["content"] == "good"

    def test_unknown_kind_is_rejected(self, home):
        with pytest.raises(ValueError):
            pw.pending_dir("nonsense")
