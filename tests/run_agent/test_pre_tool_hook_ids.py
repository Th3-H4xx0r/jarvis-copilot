"""The pre_tool_call plugin hook learns which session and tool call it is
about, on both tool loops (the jarvis-island plugin needs them to show
Jarvis's own tool calls; sweep finding)."""
import json
from types import SimpleNamespace
from unittest.mock import patch

from tests.run_agent.test_tool_call_guardrail_runtime import _make_agent, _mock_tool_call


def _capture():
    seen = []

    def fake(tool_name, args, task_id="", session_id="", tool_call_id=""):
        seen.append({"tool": tool_name, "session_id": session_id, "tool_call_id": tool_call_id})
        return None

    return seen, fake


def test_sequential_loop_passes_session_and_call_ids():
    agent = _make_agent("web_search")
    agent.session_id = "sess-42"
    seen, fake = _capture()
    msg = SimpleNamespace(content="", tool_calls=[_mock_tool_call("web_search", json.dumps({"q": "x"}), "call-7")])
    with patch("jarviscopilot_cli.plugins.get_pre_tool_call_block_message", side_effect=fake), \
            patch("run_agent.handle_function_call", return_value=json.dumps({"ok": True})):
        agent._execute_tool_calls_sequential(msg, [], "task-1")
    assert seen and seen[0] == {"tool": "web_search", "session_id": "sess-42", "tool_call_id": "call-7"}


def test_concurrent_loop_passes_session_and_call_ids():
    agent = _make_agent("web_search")
    agent.session_id = "sess-43"
    seen, fake = _capture()
    calls = [_mock_tool_call("web_search", json.dumps({"q": str(i)}), f"call-{i}") for i in range(2)]
    msg = SimpleNamespace(content="", tool_calls=calls)
    with patch("jarviscopilot_cli.plugins.get_pre_tool_call_block_message", side_effect=fake), \
            patch("run_agent.handle_function_call", return_value=json.dumps({"ok": True})):
        agent._execute_tool_calls_concurrent(msg, [], "task-1")
    assert {s["tool_call_id"] for s in seen} == {"call-0", "call-1"}
    assert {s["session_id"] for s in seen} == {"sess-43"}
