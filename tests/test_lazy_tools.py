"""Tests for lazy tool-schema loading (ToolSearch pattern)."""

import json

import pytest

import tools.lazy_tools as lt
from tools.lazy_tools import (
    partition_lazy_tools, build_manifest_text, resolve_query,
    get_lazy_core_names, lazy_tools_enabled, handle_tool_search,
)
from tools.registry import registry


def _defs(*names):
    return [{"type": "function",
             "function": {"name": n, "description": f"{n} does {n} things."}}
            for n in names]


# ── partition ────────────────────────────────────────────────────────────────

def test_partition_keeps_core_drops_rest():
    full = _defs("web_search", "terminal", "browser_navigate", "delegate_task")
    core, deferred = partition_lazy_tools(full, {"web_search", "terminal", "tool_search"})
    assert {d["function"]["name"] for d in core} == {"web_search", "terminal"}
    assert {e["name"] for e in deferred} == {"browser_navigate", "delegate_task"}
    assert all(e.get("description") for e in deferred)


def test_partition_union_is_full():
    full = _defs("a", "b", "c")
    core, deferred = partition_lazy_tools(full, {"a"})
    assert {d["function"]["name"] for d in core} | {e["name"] for e in deferred} == {"a", "b", "c"}


def test_partition_uses_first_sentence_only():
    full = [{"type": "function", "function": {
        "name": "x", "description": "Short summary. Long second sentence with detail.\nAnd more."}}]
    _, deferred = partition_lazy_tools(full, set())
    assert deferred[0]["description"] == "Short summary"


# ── manifest ─────────────────────────────────────────────────────────────────

def test_manifest_lists_every_deferred_tool_once():
    deferred = [{"name": "browser_navigate", "description": "Open a URL", "toolset": "browser"},
                {"name": "delegate_task", "description": "Spawn a subagent", "toolset": "delegation"}]
    text = build_manifest_text(deferred)
    assert text.count("browser_navigate") == 1
    assert "Open a URL" in text and "delegate_task" in text
    # grouped by toolset header
    assert "browser" in text and "delegation" in text


def test_manifest_empty_when_nothing_deferred():
    assert build_manifest_text([]) == ""


# ── query resolution ─────────────────────────────────────────────────────────

def test_resolve_query_select_exact_preserves_order():
    got = resolve_query("select:browser_navigate,delegate_task",
                        ["delegate_task", "browser_navigate", "x"])
    assert got == ["browser_navigate", "delegate_task"]


def test_resolve_query_select_drops_unknown():
    assert resolve_query("select:nope,web_search", ["web_search", "memory"]) == ["web_search"]


def test_resolve_query_keyword_ranks_hits():
    got = resolve_query("navigate browser", ["browser_navigate", "memory", "web_search"])
    assert got and got[0] == "browser_navigate"


def test_resolve_query_empty_returns_nothing():
    assert resolve_query("", ["a", "b"]) == []


# ── config gating ────────────────────────────────────────────────────────────

def test_lazy_tools_enabled_default_true(monkeypatch):
    monkeypatch.setattr(lt, "load_config", lambda: {"agent": {}}, raising=False)
    assert lazy_tools_enabled() is True


def test_lazy_tools_enabled_honors_false(monkeypatch):
    monkeypatch.setattr(lt, "load_config", lambda: {"agent": {"lazy_tools": False}}, raising=False)
    assert lazy_tools_enabled() is False


def test_core_names_always_include_tool_search(monkeypatch):
    monkeypatch.setattr(lt, "load_config", lambda: {"agent": {"lazy_tools_core": ["web_search"]}}, raising=False)
    names = get_lazy_core_names()
    assert "tool_search" in names and "web_search" in names


def test_check_fn_gates_tool_search_with_config(monkeypatch):
    # tool_search's registry check_fn follows the config flag — so when lazy is
    # off it is filtered out of get_tool_definitions (legacy behavior restored).
    monkeypatch.setattr(lt, "load_config", lambda: {"agent": {"lazy_tools": False}}, raising=False)
    assert lt._check_lazy_tools() is False
    monkeypatch.setattr(lt, "load_config", lambda: {"agent": {"lazy_tools": True}}, raising=False)
    assert lt._check_lazy_tools() is True


# ── tool_search registration + handler ───────────────────────────────────────

def test_tool_search_registered():
    assert registry.get_entry("tool_search") is not None


class _FakeAgent:
    def __init__(self, core_names):
        self.tools = [{"type": "function", "function": {"name": n}} for n in core_names]
        self.valid_tool_names = set(core_names)


@pytest.fixture
def deferred_tool():
    """A throwaway registered tool with no check_fn — avoids depending on a real
    tool's availability (API keys etc.) in handler tests."""
    name = "_lazytest_tool"
    registry.register(
        name=name, toolset="lazytest",
        schema={"name": name, "description": "Throwaway test tool.",
                "parameters": {"type": "object", "properties": {}}},
        handler=lambda args, **kw: "ok",
    )
    try:
        yield name
    finally:
        registry.deregister(name)


def test_handle_tool_search_loads_and_promotes(deferred_tool):
    agent = _FakeAgent({"tool_search", "web_search"})
    out = json.loads(handle_tool_search(agent, {"query": f"select:{deferred_tool}"}))
    assert deferred_tool in out["loaded"]
    assert deferred_tool in agent.valid_tool_names
    assert any(t["function"]["name"] == deferred_tool for t in agent.tools)
    assert out["schemas"] and out["schemas"][0]["name"] == deferred_tool


def test_handle_tool_search_no_match():
    agent = _FakeAgent({"tool_search"})
    out = json.loads(handle_tool_search(agent, {"query": "select:definitely_not_a_tool_xyz"}))
    assert out["loaded"] == []


def test_handle_tool_search_idempotent(deferred_tool):
    agent = _FakeAgent({"tool_search"})
    handle_tool_search(agent, {"query": f"select:{deferred_tool}"})
    n = len(agent.tools)
    handle_tool_search(agent, {"query": f"select:{deferred_tool}"})
    assert len(agent.tools) == n  # no duplicate advertisement


# ── safety valve: deferred tools remain dispatchable ─────────────────────────

def test_deferred_tool_still_resolvable_in_registry(deferred_tool):
    # Even when not advertised, dispatch resolves from the global registry.
    assert registry.get_entry(deferred_tool) is not None


# ── apply_lazy_partition: mid-session re-partition safety ────────────────────

class _AgentForPartition:
    def __init__(self, tool_names):
        self.tools = [{"type": "function", "function": {"name": n, "description": f"{n} does it."}}
                      for n in tool_names]
        self.valid_tool_names = set(tool_names)


def _enable_lazy(monkeypatch, on=True):
    monkeypatch.setattr(lt, "load_config", lambda: {"agent": {"lazy_tools": on}}, raising=False)


def test_apply_partition_keeps_core_and_builds_manifest(monkeypatch):
    _enable_lazy(monkeypatch)
    a = _AgentForPartition(["tool_search", "web_search", "memory"] + [f"d{i}" for i in range(7)])
    lt.apply_lazy_partition(a)
    adv = {t["function"]["name"] for t in a.tools}
    assert {"tool_search", "web_search", "memory"} <= adv
    assert "d0" not in adv                       # deferred out of advertisement
    assert "d0" in a._lazy_all_tool_names        # but still available
    assert a._lazy_tools_manifest                # manifest built


def test_apply_partition_noop_below_threshold(monkeypatch):
    _enable_lazy(monkeypatch)
    a = _AgentForPartition(["tool_search", "web_search", "d0", "d1"])  # only 2 deferrable
    lt.apply_lazy_partition(a)
    assert len(a.tools) == 4                      # unchanged
    assert a._lazy_tools_manifest == ""


def test_apply_partition_preserves_loaded_tools(monkeypatch):
    # A tool loaded earlier via tool_search must stay advertised across a
    # mid-session re-partition (MCP reload), not drop back to the manifest.
    _enable_lazy(monkeypatch)
    a = _AgentForPartition(["tool_search", "web_search"] + [f"d{i}" for i in range(7)])
    a._lazy_loaded_tools = {"d3"}
    lt.apply_lazy_partition(a)
    adv = {t["function"]["name"] for t in a.tools}
    assert "d3" in adv


def test_apply_partition_noop_when_disabled(monkeypatch):
    _enable_lazy(monkeypatch, on=False)
    a = _AgentForPartition(["tool_search", "web_search"] + [f"d{i}" for i in range(8)])
    lt.apply_lazy_partition(a)
    assert len(a.tools) == 10                     # full set untouched
    assert a._lazy_tools_manifest == ""


def test_available_tool_names_includes_deferred():
    a = _AgentForPartition(["tool_search", "web_search"])
    a._lazy_all_tool_names = {"tool_search", "web_search", "browser_navigate"}
    assert "browser_navigate" in lt.available_tool_names(a)


def test_available_tool_names_fallback_to_valid():
    class _A:
        valid_tool_names = {"x", "y"}
    assert lt.available_tool_names(_A()) == {"x", "y"}
