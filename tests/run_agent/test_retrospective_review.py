"""Tests for the outcome-driven retrospective review mode."""
from __future__ import annotations

import run_agent as _ra
from agent.background_review import (
    spawn_background_review_thread,
    _RETROSPECTIVE_REVIEW_PROMPT,
    _COMBINED_REVIEW_PROMPT,
)

# Capture the real class at import time so monkeypatching run_agent.AIAgent
# (to inject a fake review fork) doesn't also swap out the parent agent class.
_REAL_AIAGENT = _ra.AIAgent


class _Agent:
    pass


def test_review_outcome_selects_retrospective_prompt():
    target, prompt = spawn_background_review_thread(
        _Agent(), [], review_outcome=True,
    )
    assert prompt == _RETROSPECTIVE_REVIEW_PROMPT
    assert callable(target)


def test_memory_and_skills_still_select_combined():
    _, prompt = spawn_background_review_thread(
        _Agent(), [], review_memory=True, review_skills=True,
    )
    assert prompt == _COMBINED_REVIEW_PROMPT


def test_retrospective_prompt_mentions_grade_and_memory_tool():
    p = _RETROSPECTIVE_REVIEW_PROMPT.lower()
    assert "success" in p and "partial" in p and "failure" in p
    assert "memory" in p  # writes lessons via the memory tool


def test_spawn_passes_review_outcome(monkeypatch):
    import run_agent as run_agent_module
    from run_agent import AIAgent

    captured = {}

    def fake_spawn(agent, snapshot, **kwargs):
        captured.update(kwargs)
        return (lambda: None, "prompt")

    monkeypatch.setattr(
        "agent.background_review.spawn_background_review_thread", fake_spawn
    )

    class _ImmediateThread:
        def __init__(self, *, target, daemon=None, name=None):
            self._t = target

        def start(self):
            self._t()

    monkeypatch.setattr(run_agent_module.threading, "Thread", _ImmediateThread)

    agent = object.__new__(AIAgent)
    agent._spawn_background_review([], review_outcome=True)
    assert captured.get("review_outcome") is True


def _bare_agent():
    """Minimal AIAgent instance for driving _run_review_in_thread (no __init__)."""
    import datetime as _dt
    agent = object.__new__(_REAL_AIAGENT)
    agent.model = "fake-model"
    agent.platform = "cli"
    agent.provider = "openai"
    agent.base_url = ""
    agent.api_key = ""
    agent.api_mode = ""
    agent.session_id = "old-session"
    agent._parent_session_id = ""
    agent._credential_pool = None
    agent._memory_store = object()  # sentinel: fork must NOT reuse this object
    agent._memory_enabled = True
    agent._user_profile_enabled = False
    agent._cached_system_prompt = "old-cached-prompt"
    agent.session_start = _dt.datetime(2026, 1, 1, 12, 0, 0)
    agent.background_review_callback = None
    agent.status_callback = None
    agent._safe_print = lambda *_a, **_kw: None
    return agent


class _ImmediateThread:
    def __init__(self, *, target, daemon=None, name=None):
        self._t = target

    def start(self):
        self._t()


def test_retrospective_fork_is_self_contained(monkeypatch, tmp_path):
    """The retrospective fork must use its OWN memory store, a memory-only
    tool whitelist, and the pre-rotation session snapshot — so it cannot race
    new_session's concurrent store reload / session rotation."""
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    import run_agent as run_agent_module
    from run_agent import AIAgent
    import jarviscopilot_cli.plugins as plugins_mod

    captured = {}
    whitelist = {}

    class FakeReviewAgent:
        def __init__(self, **kwargs):
            self._session_messages = []

        def run_conversation(self, **kwargs):
            captured["origin"] = self._memory_write_origin
            captured["memory_store"] = self._memory_store
            captured["session_id"] = self.session_id
            captured["cached_prompt"] = self._cached_system_prompt

        def shutdown_memory_provider(self):
            pass

        def close(self):
            pass

    monkeypatch.setattr(run_agent_module, "AIAgent", FakeReviewAgent)
    monkeypatch.setattr(run_agent_module.threading, "Thread", _ImmediateThread)
    monkeypatch.setattr(plugins_mod, "set_thread_tool_whitelist",
                        lambda wl, **kw: whitelist.update(wl=wl))
    monkeypatch.setattr(plugins_mod, "clear_thread_tool_whitelist", lambda: None)

    agent = _bare_agent()
    AIAgent._spawn_background_review(
        agent,
        messages_snapshot=[{"role": "user", "content": "hi"}],
        review_outcome=True,
    )

    assert captured["origin"] == "retrospective"
    # Own store, not the shared parent object (fixes the session-boundary race).
    assert captured["memory_store"] is not agent._memory_store
    # Pre-rotation snapshot, not whatever new_session would rotate to.
    assert captured["session_id"] == "old-session"
    assert captured["cached_prompt"] == "old-cached-prompt"
    # Memory-only whitelist: cannot author an (unmanaged) skill.
    assert "memory" in whitelist["wl"]
    assert "skill_manage" not in whitelist["wl"]
