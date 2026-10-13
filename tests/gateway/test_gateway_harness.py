"""Telegram / iMessage run the one default harness (2026-10-12): "can you add support for a harness
to be used as the default instead of it being a single model only. Add this across all platforms".

Fakes only: no network, no real agent, no real harness store."""
from types import SimpleNamespace

import pytest

from gateway import harness_turns as ht

ROUTER = {"id": "router", "name": "Router", "nodes": [
    {"id": "in", "type": "message", "x": 0, "y": 0},
    {"id": "fast", "type": "answer", "model": "@anthropic-api:claude-haiku-5-5", "tools": "all", "x": 200, "y": 0,
     "instructions": "Be brief."},
    {"id": "bg", "type": "background", "model": "@anthropic-api:claude-sonnet-5-5", "tools": "all",
     "x": 400, "y": 0}],
    "edges": [{"from": "in", "to": "fast", "when": "always"}, {"from": "fast", "to": "bg", "when": "handoff"}]}

AFTER = {"id": "after", "name": "After", "nodes": [
    {"id": "in", "type": "message", "x": 0, "y": 0},
    {"id": "a", "type": "answer", "model": "@session", "x": 200, "y": 0},
    {"id": "bg", "type": "background", "model": "@anthropic-api:claude-sonnet-5-5", "x": 400, "y": 0},
    {"id": "rv", "type": "review", "model": "@anthropic-api:claude-sonnet-5-5", "x": 400, "y": 100}],
    "edges": [{"from": "in", "to": "a", "when": "always"}, {"from": "a", "to": "bg", "when": "tools:2"},
              {"from": "a", "to": "rv", "when": "always"}]}


class _Store:
    def __init__(self, default, docs):
        self.default, self.docs = default, docs

    def effective(self, surface):
        assert surface == "messaging"
        return self.default

    def get(self, hid):
        return self.docs.get(hid)


@pytest.fixture
def harness(monkeypatch):
    def install(default="router", docs=None):
        monkeypatch.setattr("agent.harness.store.store_for_home",
                            lambda: _Store(default, docs if docs is not None else {"router": ROUTER, "after": AFTER}))
    monkeypatch.setattr(ht, "_runtime_for", lambda provider: {"provider": provider, "api_key": "k",
                                                               "base_url": None, "api_mode": None,
                                                               "command": None, "args": [], "credential_pool": None})
    return install


def _plan(text="hi", **kw):
    return ht.plan_message(text, session_model=kw.get("model", "claude-sonnet-5-5"),
                           session_provider=kw.get("provider", "anthropic-api"),
                           has_session_override=kw.get("override", False))


def test_a_single_default_changes_nothing(harness):
    harness(default="single")
    assert _plan() is None


def test_a_session_model_override_wins(harness):
    harness()
    assert _plan(override=True) is None


def test_plans_the_answer_node(harness):
    harness()
    mp = _plan()
    assert mp.harness_id == "router" and mp.model == "claude-haiku-5-5" and mp.provider == "anthropic-api"
    assert mp.runtime is None  # same provider as the session: keep its credentials
    assert mp.plan.handoff_node["id"] == "bg"


def test_a_node_on_another_provider_gets_its_credentials(harness):
    harness()
    mp = _plan(provider="openai-codex", model="gpt-6.1-sol")
    assert mp.runtime["provider"] == "anthropic-api"


def test_no_credentials_for_the_node_means_the_default_model(harness, monkeypatch):
    harness()

    def no_creds(provider):
        raise RuntimeError("no key")
    monkeypatch.setattr(ht, "_runtime_for", no_creds)
    assert _plan(provider="openai-codex") is None


@pytest.mark.parametrize("docs", [{}, {"router": {"id": "router", "nodes": [], "edges": []}}])
def test_a_missing_or_broken_default_means_the_default_model(harness, docs):
    harness(docs=docs)
    assert _plan() is None


def _agent():
    return SimpleNamespace(tools=[], valid_tool_names=set(), allowed_tool_names=None,
                           _turn_user_context="", max_iterations=90)


def test_the_handoff_runs_the_background_node_and_posts_the_result(harness, monkeypatch):
    harness()
    mp = _plan("find flights")
    sent, bound = [], {}
    monkeypatch.setattr("agent.escalation.bind_turn_context",
                        lambda task_id, **kw: bound.update(kw, task_id=task_id))
    monkeypatch.setattr(ht, "_run_background_node", lambda node, prompt, **kw: f"{node['id']} did: {prompt[:12]}")
    agent = _agent()
    ht.apply_node(agent, mp, task_id="t1", deliver=sent.append, platform="telegram")
    assert "Be brief." in agent._turn_user_context and "handoff" in agent._turn_user_context
    assert bound["task_id"] == "t1" and "handoff" in agent.valid_tool_names
    out = bound["runner"]({"summary": "find flights to SF", "reason": "needs research"})
    assert out == "" and sent == ["bg did: find flights"]


def test_a_reused_agent_loses_the_last_nodes_limits(harness):
    harness()
    agent = _agent()
    agent.allowed_tool_names = frozenset()
    agent.max_iterations = 1
    agent._jc_harness_node = {"max_iterations": 90}
    ht.clear_node(agent)
    assert agent.allowed_tool_names is None and agent.max_iterations == 90


def test_after_nodes_post_a_follow_up_and_skip_reviews(harness, monkeypatch):
    harness(default="after")
    mp = _plan("research robot vacuums")
    sent = []
    monkeypatch.setattr(ht, "_run_background_node", lambda node, prompt, **kw: f"{node['id']} finished")
    threads = ht.after_turn(mp, task_id="t2", question="research robot vacuums", answer="On it.",
                            elapsed_s=3.0, tool_count=5, deliver=sent.append, platform="telegram")
    for t in threads:
        t.join(timeout=5)
    assert sent == ["bg finished"]
    assert ht.after_turn(mp, task_id="t2", question="q", answer="a", elapsed_s=1.0, tool_count=1,
                         deliver=sent.append, platform="telegram") == []
