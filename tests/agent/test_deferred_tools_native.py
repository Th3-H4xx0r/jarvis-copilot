"""Plan 2.3 / 2.4 — server-side tool search + eager device-tool input streaming.

On the native Anthropic fast lane the in-repo ``tool_search`` round trip is
replaced with Anthropic's own ``tool_search_tool_bm25_20251119`` server tool:
every non-core tool is sent with ``defer_loading: true`` so its schema never
enters the billed prefix, while device tools + a small core set stay loaded.

Device tools additionally get ``eager_input_streaming: true`` so their arguments
arrive before the model finishes the sentence (plan 2.4).
"""
from __future__ import annotations

import json

import pytest

from tools import lazy_tools
from tools.registry import registry


def _fn_tool(name: str, desc: str = "d") -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": desc,
            "parameters": {"type": "object", "properties": {}},
        },
    }


def _anthropic_tools(names):
    """Anthropic-shaped tool defs (what build_anthropic_kwargs emits)."""
    return [
        {"name": n, "description": "d", "input_schema": {"type": "object", "properties": {}}}
        for n in names
    ]


@pytest.fixture
def device_tool():
    """A tool registered under toolset ``devices`` AFTER import time.

    WS-C creates tools/device_skill_tools.py; nothing here may depend on that
    module existing, so the lookup must be a live registry query.
    """
    registry.register(
        name="open_app",
        toolset="devices",
        schema={"name": "open_app", "description": "Open an app",
                "parameters": {"type": "object", "properties": {}}},
        handler=lambda args, **kw: "{}",
    )
    try:
        yield "open_app"
    finally:
        registry.deregister("open_app")


class TestNativeDeferredToolShaping:
    def test_core_tools_are_not_deferred(self):
        tools = _anthropic_tools(["terminal", "read_file", "some_rare_tool"])
        out = lazy_tools.build_native_deferred_tools(tools)
        by_name = {t.get("name"): t for t in out}
        assert not by_name["terminal"].get("defer_loading")
        assert not by_name["read_file"].get("defer_loading")
        assert by_name["some_rare_tool"]["defer_loading"] is True

    def test_bm25_search_tool_is_appended_once_and_not_deferred(self):
        tools = _anthropic_tools(["terminal", "a", "b"])
        out = lazy_tools.build_native_deferred_tools(tools)
        search = [t for t in out if t.get("type") == lazy_tools.ANTHROPIC_TOOL_SEARCH_TYPE]
        assert len(search) == 1
        assert search[0]["name"] == lazy_tools.ANTHROPIC_TOOL_SEARCH_NAME
        assert "defer_loading" not in search[0]

        # Idempotent: shaping an already-shaped list must not duplicate it.
        again = lazy_tools.build_native_deferred_tools(out)
        assert len([t for t in again if t.get("type") == lazy_tools.ANTHROPIC_TOOL_SEARCH_TYPE]) == 1

    def test_never_defers_every_tool(self):
        """API 400s with 'All tools have defer_loading set' otherwise."""
        tools = _anthropic_tools(["rare_one", "rare_two"])
        out = lazy_tools.build_native_deferred_tools(tools)
        real = [t for t in out if t.get("type") != lazy_tools.ANTHROPIC_TOOL_SEARCH_TYPE]
        assert any(not t.get("defer_loading") for t in real)

    def test_in_repo_tool_search_is_dropped(self):
        tools = _anthropic_tools(["tool_search", "terminal", "rare"])
        out = lazy_tools.build_native_deferred_tools(tools)
        assert "tool_search" not in {t.get("name") for t in out}

    def test_device_tools_stay_loaded_and_stream_eagerly(self, device_tool):
        tools = _anthropic_tools(["open_app", "rare"])
        out = lazy_tools.build_native_deferred_tools(tools)
        by_name = {t.get("name"): t for t in out}
        assert not by_name["open_app"].get("defer_loading")
        assert by_name["open_app"]["eager_input_streaming"] is True
        assert by_name["rare"]["defer_loading"] is True
        assert "eager_input_streaming" not in by_name["rare"]

    def test_escalate_is_never_deferred(self):
        """The fast model must be able to reach for the big one without a search."""
        out = lazy_tools.build_native_deferred_tools(
            _anthropic_tools(["escalate", "rare"]))
        by_name = {t.get("name"): t for t in out}
        assert not by_name["escalate"].get("defer_loading")
        assert "escalate" in lazy_tools.get_lazy_core_names()

    def test_in_repo_tool_search_survives_a_live_client_manifest(self):
        """A stale session may still carry the client-side manifest in its
        system prompt; stripping the tool it names would strand the model."""
        class _Agent:
            _lazy_tools_manifest = "# Deferred tools\n- spotify"

        kwargs = {"tools": _anthropic_tools(["tool_search", "terminal", "rare"])}
        lazy_tools.apply_native_tool_search(kwargs, _Agent())
        assert "tool_search" in {t.get("name") for t in kwargs["tools"]}

        # Even without a manifest the in-repo tool_search stays: the system
        # prompt's "load it with tool_search" guidance is emitted from more
        # than the manifest, and a model told to call a missing tool gives up.
        kwargs = {"tools": _anthropic_tools(["tool_search", "terminal", "rare"])}
        lazy_tools.apply_native_tool_search(kwargs, None)
        names = {t.get("name") for t in kwargs["tools"]}
        assert "tool_search" in names and "tool_search_tool_bm25" in names

    def test_empty_tool_list_is_left_alone(self):
        assert lazy_tools.build_native_deferred_tools([]) == []

    def test_input_list_is_not_mutated(self):
        tools = _anthropic_tools(["terminal", "rare"])
        before = json.dumps(tools)
        lazy_tools.build_native_deferred_tools(tools)
        assert json.dumps(tools) == before


class TestNativeToolSearchGating:
    def test_enabled_by_default(self, monkeypatch):
        monkeypatch.setattr(lazy_tools, "load_config", lambda: {})
        assert lazy_tools.native_tool_search_enabled() is True

    def test_config_can_disable(self, monkeypatch):
        monkeypatch.setattr(lazy_tools, "load_config", lambda: {"tools": {"deferred": False}})
        assert lazy_tools.native_tool_search_enabled() is False

    def test_only_native_anthropic_endpoints(self):
        class _Agent:
            api_mode = "anthropic_messages"
            _anthropic_base_url = None
        assert lazy_tools.uses_native_tool_search(_Agent()) is True

        class _ThirdParty(_Agent):
            _anthropic_base_url = "https://api.kimi.com/coding"
        assert lazy_tools.uses_native_tool_search(_ThirdParty()) is False

        class _Chat(_Agent):
            api_mode = "chat_completions"
        assert lazy_tools.uses_native_tool_search(_Chat()) is False

    def test_lazy_partition_is_skipped_for_native_search(self, monkeypatch):
        """The in-repo manifest + tool_search round trip must not also run."""
        monkeypatch.setattr(lazy_tools, "load_config", lambda: {})

        class _Agent:
            api_mode = "anthropic_messages"
            _anthropic_base_url = None
            tools = [_fn_tool(f"t{i}") for i in range(20)] + [_fn_tool("tool_search")]
            valid_tool_names: set = set()

        agent = _Agent()
        lazy_tools.apply_lazy_partition(agent)
        assert agent._lazy_tools_manifest == ""
        assert len(agent.tools) == 20, "tools must stay whole; only tool_search is dropped"
        assert "tool_search" not in {t["function"]["name"] for t in agent.tools}


class TestRequestBodyShape:
    """Fake-transport style check of the final Anthropic request body."""

    def test_deferred_request_body(self, device_tool, monkeypatch):
        monkeypatch.setattr(lazy_tools, "load_config", lambda: {})
        from agent.anthropic_adapter import build_anthropic_kwargs

        kwargs = build_anthropic_kwargs(
            model="claude-haiku-4-5",
            messages=[
                {"role": "system", "content": "sys"},
                {"role": "user", "content": "open safari"},
            ],
            tools=[_fn_tool("open_app"), _fn_tool("terminal"), _fn_tool("spotify")],
            max_tokens=256,
            reasoning_config=None,
        )
        kwargs["tools"] = lazy_tools.build_native_deferred_tools(kwargs["tools"])

        names = [t.get("name") for t in kwargs["tools"]]
        assert lazy_tools.ANTHROPIC_TOOL_SEARCH_NAME in names
        body = {t.get("name"): t for t in kwargs["tools"]}
        assert body["spotify"]["defer_loading"] is True
        assert body["open_app"].get("eager_input_streaming") is True
        assert not body["terminal"].get("defer_loading")
        # Nothing else about the request shape changed.
        assert kwargs["model"] == "claude-haiku-4-5"
        assert kwargs["tool_choice"] == {"type": "auto"}
