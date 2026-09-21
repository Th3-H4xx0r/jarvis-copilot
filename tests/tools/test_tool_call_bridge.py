"""The bridge that lets a searched tool run without breaking the prompt cache.

Promoting a tool into ``agent.tools`` changes the head of the cached prefix, so
every ``tool_search`` used to re-prefill the entire conversation. ``tool_call``
is a stable core tool that dispatches by name, so the advertised array stays
byte-identical for the whole session.
"""

import json
import types

import pytest

import tools.lazy_tools as lt
from tools.lazy_tools import (
    TOOL_CALL_SCHEMA,
    build_manifest_text,
    handle_tool_call,
)
from tools.registry import registry


@pytest.fixture
def bridged_tool():
    """A throwaway tool so the test does not depend on API keys."""
    name = "_bridgetest_tool"
    registry.register(
        name=name,
        toolset="bridgetest",
        schema={"name": name, "description": "Throwaway.",
                "parameters": {"type": "object",
                               "properties": {"echo": {"type": "string"}}}},
        handler=lambda args, **kw: json.dumps({"echoed": args.get("echo")}),
    )
    try:
        yield name
    finally:
        registry.deregister(name)


def _agent(known):
    return types.SimpleNamespace(
        tools=[{"type": "function", "function": {"name": "terminal", "parameters": {}}}],
        valid_tool_names={"terminal"},
        _lazy_all_tool_names=set(known),
    )


class TestDispatch:
    def test_bridged_call_reaches_the_real_tool(self, bridged_tool):
        out = json.loads(handle_tool_call(
            _agent({bridged_tool}), {"name": bridged_tool, "arguments": {"echo": "hi"}}))
        assert out == {"echoed": "hi"}

    def test_arguments_as_a_json_string_are_accepted(self, bridged_tool):
        """Some models send `arguments` already serialized."""
        out = json.loads(handle_tool_call(
            _agent({bridged_tool}),
            {"name": bridged_tool, "arguments": '{"echo": "hi"}'}))
        assert out == {"echoed": "hi"}

    def test_missing_arguments_default_to_empty(self, bridged_tool):
        out = json.loads(handle_tool_call(
            _agent({bridged_tool}), {"name": bridged_tool}))
        assert out == {"echoed": None}

    def test_dispatch_does_not_mutate_the_tool_list(self, bridged_tool):
        agent = _agent({bridged_tool})
        before = [t["function"]["name"] for t in agent.tools]
        handle_tool_call(agent, {"name": bridged_tool, "arguments": {"echo": "x"}})
        assert [t["function"]["name"] for t in agent.tools] == before
        assert agent.valid_tool_names == {"terminal"}


class TestTheBridgeIsNotAWayAroundToolsets:
    """It dispatches by name, so it must only reach what the session knows."""

    def test_unknown_tool_is_refused(self):
        out = json.loads(handle_tool_call(
            _agent({"something_else"}), {"name": "rm_everything", "arguments": {}}))
        assert "error" in out
        assert "not available" in out["error"]

    def test_a_tool_outside_the_manifest_is_refused(self, bridged_tool):
        """Registered is not enough -- it has to be in THIS session's manifest."""
        out = json.loads(handle_tool_call(
            _agent(set()), {"name": bridged_tool, "arguments": {}}))
        assert "error" in out

    def test_an_advertised_tool_is_allowed(self):
        agent = _agent(set())
        out = json.loads(handle_tool_call(agent, {"name": "terminal", "arguments": {}}))
        assert "not available" not in json.dumps(out)

    @pytest.mark.parametrize("name", ["tool_call", "tool_search"])
    def test_it_cannot_invoke_itself_or_the_search(self, name):
        out = json.loads(handle_tool_call(
            _agent({name}), {"name": name, "arguments": {}}))
        assert "error" in out


class TestMalformedInput:
    def test_no_name(self):
        assert "error" in json.loads(handle_tool_call(_agent(set()), {"arguments": {}}))

    def test_unparseable_argument_string(self, bridged_tool):
        out = json.loads(handle_tool_call(
            _agent({bridged_tool}), {"name": bridged_tool, "arguments": "not json"}))
        assert "error" in out

    def test_non_object_arguments(self, bridged_tool):
        out = json.loads(handle_tool_call(
            _agent({bridged_tool}), {"name": bridged_tool, "arguments": [1, 2]}))
        assert "error" in out


class TestSchema:
    def test_schema_requires_name_and_arguments(self):
        req = TOOL_CALL_SCHEMA["parameters"]["required"]
        assert set(req) == {"name", "arguments"}

    def test_arguments_accepts_arbitrary_properties(self):
        """Each bridged tool has its own shape, so this cannot be closed."""
        props = TOOL_CALL_SCHEMA["parameters"]["properties"]
        assert props["arguments"].get("additionalProperties") is True


class TestTheManifestTeachesTheContract:
    """The bug that shipped: the mechanism changed and the text did not.

    The old manifest said "call tool_search to load a schema before using it
    IF you are unsure of its arguments" -- which made the search sound optional
    and implied the tool could then be called by name. The model called
    send_email cold, got "does not exist", searched, called it by name again,
    and burned twelve tool calls before claiming success it never had.
    """

    DEFERRED = [{"name": "send_email", "description": "Send an email",
                 "toolset": "messaging"}]

    def test_bridge_on_says_a_direct_call_will_fail(self, monkeypatch):
        monkeypatch.setattr(lt, "bridge_enabled", lambda: True)
        text = build_manifest_text(self.DEFERRED)
        assert "WILL FAIL" in text
        assert "tool_call(name=" in text

    def test_bridge_on_does_not_make_the_search_sound_optional(self, monkeypatch):
        monkeypatch.setattr(lt, "bridge_enabled", lambda: True)
        text = build_manifest_text(self.DEFERRED)
        assert "if you are unsure" not in text.lower()

    def test_bridge_off_keeps_the_native_wording(self, monkeypatch):
        """With the escape hatch on, the old contract is the true one."""
        monkeypatch.setattr(lt, "bridge_enabled", lambda: False)
        text = build_manifest_text(self.DEFERRED)
        assert "tool_call(name=" not in text

    def test_the_deferred_tools_are_still_listed(self, monkeypatch):
        monkeypatch.setattr(lt, "bridge_enabled", lambda: True)
        assert "send_email" in build_manifest_text(self.DEFERRED)
