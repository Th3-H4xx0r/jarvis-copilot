"""Refreshing device tools must not duplicate a tool declaration.

Gemini rejects the whole request: "Duplicate function declaration found:
notify_phone" (400 INVALID_ARGUMENT). `notify_phone` lives in the `devices`
toolset but is not named `device_*`, so the refresh kept the copy already on
the agent and appended the toolset's copy again."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "webui"))

from api import streaming


class _Agent:
    def __init__(self, tools):
        self.tools = tools
        self.valid_tool_names = {"notify_phone"}


def _tool(name):
    return {"type": "function", "function": {"name": name, "parameters": {}}}


def _names(tools):
    return [(t.get("function") or {}).get("name") for t in tools]


def test_a_shared_toolset_tool_is_not_duplicated(monkeypatch):
    fresh = [_tool("notify_phone"), _tool("device_set_alarm")]
    monkeypatch.setattr("model_tools.get_tool_definitions",
                        lambda **kw: [dict(t) for t in fresh])
    agent = _Agent([_tool("terminal"), _tool("notify_phone"), _tool("device_stale")])

    streaming._refresh_device_tools(agent)

    names = _names(agent.tools)
    assert names.count("notify_phone") == 1, f"duplicate declaration: {names}"
    assert "terminal" in names, "unrelated tools survive"
    assert "device_stale" not in names, "a device tool that is gone is dropped"
    assert "device_set_alarm" in names
    assert "notify_phone" in agent.valid_tool_names


def test_the_refresh_is_idempotent(monkeypatch):
    fresh = [_tool("notify_phone")]
    monkeypatch.setattr("model_tools.get_tool_definitions",
                        lambda **kw: [dict(t) for t in fresh])
    agent = _Agent([_tool("notify_phone")])
    streaming._refresh_device_tools(agent)
    streaming._refresh_device_tools(agent)
    assert _names(agent.tools).count("notify_phone") == 1
