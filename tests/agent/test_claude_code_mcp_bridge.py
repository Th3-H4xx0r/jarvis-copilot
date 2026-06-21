"""Unit tests for the structured claude-code MCP bridge (no `claude` CLI needed)."""
from __future__ import annotations

from agent.claude_code_mcp_bridge import (
    McpToolBridge,
    jc_tool_name,
    mcp_tool_name,
    openai_tools_to_mcp,
)


def test_name_mapping_round_trips():
    assert mcp_tool_name("get_weather") == "mcp__jc__get_weather"
    assert jc_tool_name("mcp__jc__get_weather") == "get_weather"
    # already-prefixed / unprefixed are idempotent
    assert mcp_tool_name("mcp__jc__x") == "mcp__jc__x"
    assert jc_tool_name("plain") == "plain"


def test_openai_tools_to_mcp_maps_schema():
    tools = [{"type": "function", "function": {
        "name": "send_text", "description": "Send an SMS.",
        "parameters": {"type": "object", "properties": {"to": {"type": "string"}}, "required": ["to"]},
    }}]
    mcp = openai_tools_to_mcp(tools)
    assert mcp == [{
        "name": "send_text", "description": "Send an SMS.",
        "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}}, "required": ["to"]},
    }]


def test_openai_tools_to_mcp_tolerates_missing_params_and_junk():
    tools = [
        {"type": "function", "function": {"name": "noargs"}},   # no parameters
        {"type": "function"},                                    # no function
        {"junk": 1},                                             # not a tool
    ]
    mcp = openai_tools_to_mcp(tools)
    assert len(mcp) == 1
    assert mcp[0]["name"] == "noargs"
    assert mcp[0]["inputSchema"] == {"type": "object", "properties": {}}


def _bridge(on_call):
    tools = openai_tools_to_mcp([{"type": "function", "function": {
        "name": "echo", "parameters": {"type": "object", "properties": {"v": {"type": "string"}}}}}])
    return McpToolBridge(tools, on_call, socket_path="/tmp/unused.sock")


def test_handle_initialize_echoes_protocol_version():
    b = _bridge(lambda n, a: "x")
    r = b.handle_message({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                          "params": {"protocolVersion": "2025-06-18"}})
    assert r["id"] == 0
    assert r["result"]["protocolVersion"] == "2025-06-18"
    assert r["result"]["serverInfo"]["name"] == "jc"


def test_handle_tools_list_returns_catalog():
    b = _bridge(lambda n, a: "x")
    r = b.handle_message({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    names = [t["name"] for t in r["result"]["tools"]]
    assert names == ["echo"]


def test_handle_initialized_notification_has_no_reply():
    b = _bridge(lambda n, a: "x")
    assert b.handle_message({"method": "notifications/initialized"}) is None


def test_tools_call_invokes_executor_with_unprefixed_name():
    seen = {}

    def on_call(name, args):
        seen["name"] = name
        seen["args"] = args
        return f"ran {name}"

    b = _bridge(on_call)
    r = b.handle_message({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                          "params": {"name": "mcp__jc__echo", "arguments": {"v": "hi"}}})
    assert seen == {"name": "echo", "args": {"v": "hi"}}
    assert r["result"]["content"][0]["text"] == "ran echo"
    assert not r["result"].get("isError")


def test_tools_call_executor_error_is_returned_not_raised():
    def boom(name, args):
        raise RuntimeError("kaboom")

    b = _bridge(boom)
    r = b.handle_message({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                          "params": {"name": "mcp__jc__echo", "arguments": {}}})
    # must return an isError result (never hang/crash the CLI)
    assert r["result"]["isError"] is True
    assert "kaboom" in r["result"]["content"][0]["text"]


def test_tools_call_non_dict_arguments_default_to_empty():
    seen = {}
    b = _bridge(lambda n, a: seen.update(a) or "ok")
    b.handle_message({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                      "params": {"name": "mcp__jc__echo", "arguments": None}})
    assert seen == {}


def test_tools_call_executor_timeout_returns_error_not_hang():
    import time

    def slow(name, args):
        time.sleep(5)
        return "too late"

    tools = openai_tools_to_mcp([{"type": "function", "function": {"name": "echo"}}])
    b = McpToolBridge(tools, slow, socket_path="/tmp/unused.sock", executor_timeout=0.2)
    try:
        t0 = time.time()
        r = b.handle_message({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                              "params": {"name": "mcp__jc__echo", "arguments": {}}})
        assert time.time() - t0 < 2.0, "should not block for the full executor duration"
        assert r["result"]["isError"] is True
        assert "timed out" in r["result"]["content"][0]["text"]
    finally:
        b.close()


def test_mcp_config_json_points_at_proxy_and_socket():
    import json
    b = McpToolBridge([], lambda n, a: "", socket_path="/tmp/jc-test.sock")
    cfg = json.loads(b.mcp_config_json())
    srv = cfg["mcpServers"]["jc"]
    assert srv["command"] == "python3"
    assert srv["args"][0].endswith("claude_mcp_proxy.py")
    assert srv["env"]["JC_MCP_SOCKET"] == "/tmp/jc-test.sock"
