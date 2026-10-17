"""Codex rollout JSONL → the same chat-message list the Claude transcript
reader produces (agent/coding_transcript_read.py), so the coding chat UIs
render a Codex session without branching.

Every fixture line below is SYNTHETIC — written to match the shapes Codex
0.163 writes to ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, never copied
from a real session.
"""
import json

from agent.coding_transcript_read import parse_transcript_text, slice_messages
from agent.codex_transcript_read import (find_codex_rollout,
                                         parse_codex_rollout_text,
                                         read_codex_page)


def _line(ts: str, typ: str, payload: dict) -> str:
    return json.dumps({"timestamp": f"2026-10-01T10:00:{ts}.000Z",
                       "type": typ, "payload": payload})


def _item(ts: str, item: dict) -> str:
    return _line(ts, "event_msg", {"type": "item_completed",
                                   "thread_id": "th-1", "turn_id": "tu-1",
                                   "item": item})


# The current (0.14x–0.163) layout: model-level `response_item` lines AND the
# UI-level `event_msg` / `item_completed` items for the same turn.
ROLLOUT = "\n".join([
    _line("00", "session_meta", {"id": "th-1", "session_id": "th-1",
                                 "cwd": "/work/demo", "cli_version": "0.163.0",
                                 "originator": "codex-tui", "source": "cli"}),
    _line("01", "event_msg", {"type": "task_started", "turn_id": "tu-1",
                              "model_context_window": 258400}),
    _line("02", "response_item", {"type": "message", "role": "developer",
                                  "content": [{"type": "input_text",
                                               "text": "<permissions>…</permissions>"}]}),
    _line("03", "response_item", {"type": "message", "role": "user",
                                  "content": [{"type": "input_text",
                                               "text": "# AGENTS.md instructions for /work/demo\n\nbe nice"}]}),
    _line("04", "turn_context", {"turn_id": "tu-1", "cwd": "/work/demo",
                                 "model": "gpt-test-mini",
                                 "approval_policy": "on-request"}),
    _line("05", "response_item", {"type": "message", "role": "user",
                                  "content": [{"type": "input_text",
                                               "text": "Add a greeting"}]}),
    _item("05", {"type": "UserMessage", "id": "um-1",
                 "content": [{"type": "text", "text": "Add a greeting",
                              "text_elements": []}]}),
    _item("06", {"type": "Reasoning", "id": "rs-1", "summary_text": [],
                 "raw_content": []}),
    _item("07", {"type": "AgentMessage", "id": "msg-1", "phase": "commentary",
                 "content": [{"type": "Text", "text": "Looking at the file."}]}),
    _line("07", "response_item", {"type": "message", "role": "assistant",
                                  "phase": "commentary",
                                  "content": [{"type": "output_text",
                                               "text": "Looking at the file."}]}),
    _line("08", "response_item", {"type": "custom_tool_call", "status": "completed",
                                  "call_id": "call-1", "name": "exec",
                                  "input": "text(await tools.exec_command({cmd:\"cat hello.py\"}));\n"}),
    _item("08", {"type": "CommandExecution", "id": "exec-1",
                 "command": ["/bin/zsh", "-lc", "cat hello.py"],
                 "cwd": "file:///work/demo", "status": "completed",
                 "aggregated_output": "print('hi')\n", "exit_code": 0,
                 "stdout": "print('hi')\n", "stderr": ""}),
    _line("08", "response_item", {"type": "custom_tool_call_output", "call_id": "call-1",
                                  "output": [{"type": "input_text",
                                              "text": "Script completed\n"}]}),
    _item("09", {"type": "CommandExecution", "id": "exec-2",
                 "command": ["/bin/zsh", "-lc", "ls missing"],
                 "status": "failed", "aggregated_output": "ls: missing: No such file\n",
                 "exit_code": 1}),
    _item("10", {"type": "FileChange", "id": "patch-1", "status": "completed",
                 "changes": {
                     "/work/demo/hello.py": {
                         "type": "update", "move_path": None,
                         "unified_diff": "@@ -1 +1,2 @@\n print('hi')\n+print('hello')\n"},
                     "/work/demo/NOTES.md": {"type": "add",
                                             "content": "# Notes\nfirst\n"}}}),
    _item("11", {"type": "McpToolCall", "id": "mcp-1", "server": "memory",
                 "tool": "recall", "arguments": {"query": "greeting style"},
                 "status": "completed",
                 "result": {"content": [{"type": "text", "text": "use hello"}]}}),
    _item("12", {"type": "AgentMessage", "id": "msg-2", "phase": "final_answer",
                 "content": [{"type": "Text", "text": "Done."}]}),
    _line("12", "response_item", {"type": "message", "role": "assistant",
                                  "phase": "final_answer",
                                  "content": [{"type": "output_text", "text": "Done."}]}),
    _line("13", "event_msg", {"type": "token_count", "info": {
        "last_token_usage": {"input_tokens": 1200, "cached_input_tokens": 1000,
                             "output_tokens": 30, "total_tokens": 1230},
        "model_context_window": 258400}}),
    _line("14", "event_msg", {"type": "task_complete", "turn_id": "tu-1",
                              "last_agent_message": "Done."}),
    _item("15", {"type": "UserMessage", "id": "um-2",
                 "content": [{"type": "text",
                              "text": "<task-notification>bg job</task-notification>"}]}),
    _item("16", {"type": "UserMessage", "id": "um-3",
                 "content": [{"type": "text", "text": "Thanks"}]}),
]) + "\n"


# The model-level-only layout (no item_completed lines): tool calls and their
# outputs arrive as separate response_items joined by call_id.
RESPONSE_ONLY = "\n".join([
    _line("00", "session_meta", {"id": "th-2", "cwd": "/work/demo"}),
    _line("01", "response_item", {"type": "message", "role": "user",
                                  "content": [{"type": "input_text",
                                               "text": "<environment_context>…</environment_context>"}]}),
    _line("02", "response_item", {"type": "message", "role": "user",
                                  "content": [{"type": "input_text", "text": "Run the tests"}]}),
    _line("03", "response_item", {"type": "function_call", "name": "exec_command",
                                  "call_id": "call-9",
                                  "arguments": json.dumps({"cmd": "pytest -q",
                                                           "workdir": "/work/demo"})}),
    _line("04", "response_item", {"type": "custom_tool_call", "name": "apply_patch",
                                  "call_id": "call-10", "status": "completed",
                                  "input": "*** Begin Patch\n*** Update File: app.py\n@@\n-old()\n+new()\n*** End Patch\n"}),
    _line("05", "response_item", {"type": "function_call_output", "call_id": "call-9",
                                  "output": "3 passed in 0.1s"}),
    _line("06", "response_item", {"type": "custom_tool_call_output", "call_id": "call-10",
                                  "output": [{"type": "input_text",
                                              "text": "Success. Updated the following files:\nM app.py"}]}),
    _line("07", "response_item", {"type": "message", "role": "assistant",
                                  "content": [{"type": "output_text", "text": "All green."}]}),
]) + "\n"


def test_parses_user_and_assistant():
    msgs = parse_codex_rollout_text(ROLLOUT)
    roles = [m["role"] for m in msgs]
    assert roles == ["user", "assistant", "user"]
    assert [m["i"] for m in msgs] == [0, 1, 2]
    user, asst, last = msgs
    # Harness envelopes (AGENTS.md, developer, <task-notification>) never
    # surface as chat; the real message is not duplicated by its
    # response_item twin.
    assert user["text"] == "Add a greeting"
    assert asst["text"] == "Looking at the file.\n\nDone."
    assert last["text"] == "Thanks"
    assert isinstance(user["ts"], float)
    for m in msgs:
        assert set(m) >= {"i", "role", "text", "tools", "ts"}


def test_tool_call_and_output_paired():
    tools = parse_codex_rollout_text(ROLLOUT)[1]["tools"]
    by_summary = {t["summary"]: t for t in tools}
    ok_cmd = by_summary["cat hello.py"]
    assert ok_cmd["name"] == "Bash"
    assert ok_cmd["output"] == "print('hi')\n"
    assert ok_cmd["ok"] is True
    failed = by_summary["ls missing"]
    assert failed["ok"] is False and "No such file" in failed["output"]
    edit = by_summary["/work/demo/hello.py"]
    assert edit["name"] == "Edit" and "+print('hello')" in edit["diff"]
    write = by_summary["/work/demo/NOTES.md"]
    assert write["name"] == "Write" and write["diff"] == ["+# Notes", "+first"]
    mcp = by_summary["greeting style"]
    assert mcp["name"] == "mcp__memory__recall"
    assert mcp["output"] == "use hello" and mcp["ok"] is True
    # The code-mode `exec` wrapper call is the model-level twin of the
    # CommandExecution items — not a tool row of its own.
    assert len(tools) == 5

    # Model-level-only rollouts: call and output joined by call_id.
    msgs = parse_codex_rollout_text(RESPONSE_ONLY)
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[0]["text"] == "Run the tests"
    run, patch = msgs[1]["tools"]
    assert run["name"] == "Bash" and run["summary"] == "pytest -q"
    assert run["output"] == "3 passed in 0.1s" and run["ok"] is True
    assert patch["name"] == "Edit" and patch["summary"] == "app.py"
    assert patch["diff"] == ["-old()", "+new()"]
    assert "Updated the following files" in patch["output"]
    assert msgs[1]["text"] == "All green."


def _claude_fixture() -> str:
    return "\n".join(json.dumps(d) for d in [
        {"type": "user", "timestamp": "2026-10-01T10:00:00Z",
         "message": {"role": "user", "content": "hi"}},
        {"type": "assistant", "timestamp": "2026-10-01T10:00:01Z",
         "message": {"role": "assistant", "model": "claude-test",
                     "usage": {"input_tokens": 5, "output_tokens": 1},
                     "content": [{"type": "text", "text": "hello"},
                                 {"type": "tool_use", "id": "tu1", "name": "Bash",
                                  "input": {"command": "ls"}}]}},
        {"type": "user", "timestamp": "2026-10-01T10:00:02Z",
         "message": {"role": "user", "content": [
             {"type": "tool_result", "tool_use_id": "tu1", "content": "a.txt"}]}},
    ]) + "\n"


def test_paging_matches_claude_envelope(tmp_path):
    claude = slice_messages(parse_transcript_text(_claude_fixture()), 0, limit=50)
    f = tmp_path / "rollout-2026-10-01T10-00-00-th-1.jsonl"
    f.write_text(ROLLOUT)
    page = read_codex_page(str(f))
    assert set(page) == set(claude)
    assert set(page["context"]) == set(claude["context"])
    assert set(page["messages"][1]) == set(claude["messages"][1])
    assert set(page["messages"][1]["tools"][0]) >= set(claude["messages"][1]["tools"][0])
    assert page["total"] == 3 and page["start"] == 0
    # Codex's own context window + latest usage drive the gauge.
    assert page["context"]["window"] == 258400
    assert page["context"]["used"] == 1230
    assert page["context"]["model"] == "gpt-test-mini"
    # Internal keys never reach the wire.
    assert all("usage" not in m and "model" not in m for m in page["messages"])

    # limit opens on the tail; before pages back; after is the live tail.
    tail = read_codex_page(str(f), limit=2)
    assert tail["start"] == 1 and [m["i"] for m in tail["messages"]] == [1, 2]
    back = read_codex_page(str(f), before=1, limit=2)
    assert back["start"] == 0 and [m["i"] for m in back["messages"]] == [0]
    live = read_codex_page(str(f), after=2)
    assert [m["i"] for m in live["messages"]] == [2] and live["total"] == 3
    # lite drops tool output/diff exactly like the Claude list view.
    lite = read_codex_page(str(f), lite=True)
    edit = next(t for t in lite["messages"][1]["tools"] if t["name"] == "Edit")
    assert "diff" not in edit and edit["more"] is True and edit["added"] == 1


def test_skips_malformed_lines():
    junk = "\n".join([
        "not json at all",
        "{\"truncated\": ",
        "[1, 2, 3]",
        json.dumps({"type": "event_msg", "payload": "nope"}),
        json.dumps({"type": "event_msg", "payload": {"type": "item_completed",
                                                    "item": None}}),
        json.dumps({"type": "event_msg", "payload": {"type": "item_completed",
                                                    "item": {"type": "AgentMessage",
                                                             "content": "bad"}}}),
        json.dumps({"type": "response_item", "payload": {"type": "function_call_output",
                                                        "call_id": "nobody",
                                                        "output": 7}}),
        json.dumps({"type": "event_msg", "payload": {"type": "token_count",
                                                    "info": {"last_token_usage": "x"}}}),
    ])
    msgs = parse_codex_rollout_text(junk + "\n" + ROLLOUT + "\n{oops")
    assert [m["role"] for m in msgs] == ["user", "assistant", "user"]
    assert parse_codex_rollout_text("") == []
    assert parse_codex_rollout_text(junk) == []


def test_find_codex_rollout(tmp_path):
    day = tmp_path / "sessions" / "2026" / "10" / "01"
    day.mkdir(parents=True)
    want = day / "rollout-2026-10-01T10-00-00-01a1-th-1.jsonl"
    want.write_text(ROLLOUT)
    (day / "rollout-2026-10-01T11-00-00-01a1-th-2.jsonl").write_text("")
    assert find_codex_rollout("01a1-th-1", codex_home=str(tmp_path)) == want
    assert find_codex_rollout("nope", codex_home=str(tmp_path)) is None
    assert find_codex_rollout("", codex_home=str(tmp_path)) is None
