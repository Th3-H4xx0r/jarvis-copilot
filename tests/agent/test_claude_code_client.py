"""Tests for ClaudeCodeClient (the local-CLI inference shim).

All tests mock subprocess.run — no real `claude` calls.
"""

import json
from types import SimpleNamespace
from unittest import mock

import pytest

from agent.claude_code_client import (
    CLAUDE_CLI_MARKER_BASE_URL,
    ClaudeCodeClient,
    _map_model_to_cli,
    _norm_timeout,
)

_TOOL_CALL_RESULT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "result": (
        '<tool_call>{"id":"1","type":"function",'
        '"function":{"name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}</tool_call>'
    ),
    "stop_reason": "tool_use",
    "usage": {
        "input_tokens": 10,
        "output_tokens": 5,
        "cache_read_input_tokens": 3,
        "cache_creation_input_tokens": 2,
    },
}


def _fake_run(stdout: str = "", stderr: str = "", returncode: int = 0):
    cp = mock.Mock()
    cp.stdout = stdout
    cp.stderr = stderr
    cp.returncode = returncode
    return cp


def test_default_attributes_match_openai_client_shape():
    c = ClaudeCodeClient()
    assert c.api_key == "claude-code"
    assert c.base_url == CLAUDE_CLI_MARKER_BASE_URL
    assert c.is_closed is False
    assert hasattr(c, "chat") and hasattr(c.chat, "completions")
    assert callable(c.chat.completions.create)


def test_close_marks_closed_idempotently():
    c = ClaudeCodeClient()
    c.close()
    assert c.is_closed is True
    c.close()
    assert c.is_closed is True


def test_create_argv_contains_isolation_flags_and_pipes_prompt_via_stdin():
    c = ClaudeCodeClient()
    payload = dict(_TOOL_CALL_RESULT)
    payload["result"] = "Hello"
    payload["stop_reason"] = "end_turn"
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run(json.dumps(payload)),
    ) as run:
        c.chat.completions.create(
            model="claude-opus-4-7",
            messages=[{"role": "user", "content": "hi"}],
        )
    argv = run.call_args[0][0]
    # native tools fully disabled
    assert "--tools" in argv
    assert argv[argv.index("--tools") + 1] == ""
    # blocking JSON
    assert "--output-format" in argv and argv[argv.index("--output-format") + 1] == "json"
    # model passes through verbatim
    assert "--model" in argv and argv[argv.index("--model") + 1] == "claude-opus-4-7"
    # isolation from user/project settings and MCP
    assert "--setting-sources" in argv
    assert argv[argv.index("--setting-sources") + 1] == ""
    assert "--strict-mcp-config" in argv
    assert "--no-session-persistence" in argv
    # prompt delivered via stdin
    kwargs = run.call_args.kwargs
    assert "input" in kwargs and kwargs["input"]  # non-empty
    assert kwargs.get("text") is True
    # cwd points at a real directory (not the project)
    assert kwargs.get("cwd")


def test_create_parses_tool_call_and_usage():
    c = ClaudeCodeClient()
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run(json.dumps(_TOOL_CALL_RESULT)),
    ):
        resp = c.chat.completions.create(
            model="claude-opus-4-7",
            messages=[{"role": "user", "content": "weather?"}],
            tools=[{
                "type": "function",
                "function": {"name": "get_weather", "parameters": {}},
            }],
        )
    choice = resp.choices[0]
    assert choice.finish_reason == "tool_calls"
    assert choice.message.tool_calls
    tc = choice.message.tool_calls[0]
    assert tc.function.name == "get_weather"
    assert tc.function.arguments == '{"city":"Paris"}'
    assert tc.type == "function"
    # content should be empty/None when only a tool call is emitted
    assert not choice.message.content
    # usage maps directly from the JSON
    assert resp.usage.prompt_tokens == 10
    assert resp.usage.completion_tokens == 5
    assert resp.usage.total_tokens == 15
    assert resp.usage.prompt_tokens_details.cached_tokens == 3


def test_create_plain_text_response():
    payload = dict(_TOOL_CALL_RESULT)
    payload["result"] = "Hello there!"
    payload["stop_reason"] = "end_turn"
    c = ClaudeCodeClient()
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run(json.dumps(payload)),
    ):
        resp = c.chat.completions.create(
            model="claude-haiku-4-5", messages=[{"role": "user", "content": "hi"}]
        )
    assert resp.choices[0].message.content == "Hello there!"
    assert resp.choices[0].finish_reason == "stop"
    assert resp.choices[0].message.tool_calls == []


def test_missing_claude_binary_raises_actionable_error():
    c = ClaudeCodeClient()
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        side_effect=FileNotFoundError(),
    ):
        with pytest.raises(RuntimeError) as excinfo:
            c.chat.completions.create(
                model="claude-opus-4-7", messages=[{"role": "user", "content": "x"}]
            )
    msg = str(excinfo.value).lower()
    assert "claude" in msg
    assert "log in" in msg or "install" in msg


def test_timeout_raises_actionable_error():
    c = ClaudeCodeClient(timeout=5)
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        side_effect=__import__("subprocess").TimeoutExpired(cmd="claude", timeout=5),
    ):
        with pytest.raises(RuntimeError) as excinfo:
            c.chat.completions.create(
                model="claude-haiku-4-5", messages=[{"role": "user", "content": "x"}]
            )
    assert "timed out" in str(excinfo.value).lower()


def test_api_error_in_json_is_surfaced():
    payload = {
        "type": "result",
        "is_error": True,
        "result": "You're out of extra usage.",
    }
    c = ClaudeCodeClient()
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run(json.dumps(payload)),
    ):
        with pytest.raises(RuntimeError) as excinfo:
            c.chat.completions.create(
                model="claude-opus-4-7", messages=[{"role": "user", "content": "x"}]
            )
    assert "out of extra usage" in str(excinfo.value)


def test_non_json_output_is_surfaced_with_stderr():
    c = ClaudeCodeClient()
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run("not json at all", stderr="boom"),
    ):
        with pytest.raises(RuntimeError) as excinfo:
            c.chat.completions.create(
                model="claude-opus-4-7", messages=[{"role": "user", "content": "x"}]
            )
    assert "non-JSON" in str(excinfo.value)


def test_empty_stdout_with_nonzero_exit_is_surfaced():
    c = ClaudeCodeClient()
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run("", stderr="auth failed", returncode=1),
    ):
        with pytest.raises(RuntimeError) as excinfo:
            c.chat.completions.create(
                model="claude-opus-4-7", messages=[{"role": "user", "content": "x"}]
            )
    msg = str(excinfo.value)
    assert "auth failed" in msg


def test_model_mapping_passes_through_and_defaults():
    assert _map_model_to_cli("claude-opus-4-7") == "claude-opus-4-7"
    assert _map_model_to_cli("opus") == "opus"
    # Empty/None fall back to haiku — matches the profile's default_aux_model.
    assert _map_model_to_cli("") == "haiku"
    assert _map_model_to_cli(None) == "haiku"


def test_model_mapping_falls_back_when_non_claude_model_passed():
    """Regression: a subagent spawned by an aux/delegate config left over
    from a previous provider (e.g. ``model=gpt-5.5`` from OpenAI Codex)
    must NOT be passed straight to `claude --model gpt-5.5` — the CLI
    rejects it with a confusing 'model may not exist' error. We fall back
    to the default claude model instead."""
    from agent.claude_code_client import _LOGGED_NON_CLAUDE_MODELS
    _LOGGED_NON_CLAUDE_MODELS.clear()  # reset session de-dup
    assert _map_model_to_cli("gpt-5.5") == "haiku"
    assert _map_model_to_cli("gpt-5.5-mini") == "haiku"
    assert _map_model_to_cli("kimi-k2") == "haiku"
    # Claude variants stay untouched.
    assert _map_model_to_cli("claude-sonnet-4-6") == "claude-sonnet-4-6"
    assert _map_model_to_cli("sonnet") == "sonnet"


def test_subprocess_env_scrubs_anthropic_credentials(monkeypatch):
    """Regression: the parent's Anthropic API credentials must NOT leak into
    the `claude` subprocess — if they did, the CLI would silently bill via API
    instead of the user's Max subscription (the bug this provider exists to fix).
    """
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-leaked")
    monkeypatch.setenv("ANTHROPIC_TOKEN", "tok-leaked")
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "auth-leaked")
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "oauth-leaked")
    monkeypatch.setenv("CLAUDE_CODE_USE_BEDROCK", "1")
    monkeypatch.setenv("CLAUDE_CODE_USE_VERTEX", "1")
    monkeypatch.setenv("CLAUDECODE", "1")
    monkeypatch.setenv("CLAUDE_CODE_ENTRYPOINT", "cli")

    c = ClaudeCodeClient()
    payload = dict(_TOOL_CALL_RESULT)
    payload["result"] = "ok"
    payload["stop_reason"] = "end_turn"
    with mock.patch(
        "agent.claude_code_client.subprocess.run",
        return_value=_fake_run(json.dumps(payload)),
    ) as run:
        c.chat.completions.create(
            model="claude-haiku-4-5", messages=[{"role": "user", "content": "x"}]
        )
    env = run.call_args.kwargs["env"]
    for leaked in (
        "ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
    ):
        assert leaked not in env, f"{leaked} leaked into claude subprocess env"


def test_parse_claude_json_recovers_from_leading_log_lines():
    from agent.claude_code_client import _parse_claude_json
    assert _parse_claude_json('{"a":1}') == {"a": 1}
    assert _parse_claude_json('WARN: auto-update available\n{"result":"hi"}') == {"result": "hi"}
    assert _parse_claude_json('not json at all') is None
    assert _parse_claude_json('') is None


# ── Streaming (stream-json + --include-partial-messages) ──────────────────


class _FakePopen:
    """Minimal Popen stand-in that yields canned NDJSON lines from stdout."""
    def __init__(self, lines):
        self.stdin = mock.Mock()
        self.stderr = mock.Mock()
        self.stderr.read = lambda: ""
        self.stdout = iter(line + "\n" for line in lines)
        self._returncode = 0
    def poll(self):
        return self._returncode
    def terminate(self):
        self._returncode = 0
    def wait(self, timeout=None):
        return self._returncode
    def kill(self):
        self._returncode = -9


def _ndjson_events(*, text_chunks=None, tool_call=None, stop="end_turn"):
    """Construct a realistic claude stream-json NDJSON event list."""
    events = [
        {"type": "system", "subtype": "init"},
        {"type": "stream_event",
         "event": {"type": "message_start",
                   "message": {"model": "claude-haiku-4-5-20251001"}}},
        {"type": "stream_event",
         "event": {"type": "content_block_start", "index": 0,
                   "content_block": {"type": "text"}}},
    ]
    text_chunks = list(text_chunks or [])
    if tool_call is not None:
        full = "<tool_call>" + json.dumps(tool_call) + "</tool_call>"
        text_chunks = [full]
    for chunk in text_chunks:
        events.append({
            "type": "stream_event",
            "event": {"type": "content_block_delta", "index": 0,
                      "delta": {"type": "text_delta", "text": chunk}},
        })
    events.append({"type": "stream_event",
                   "event": {"type": "content_block_stop", "index": 0}})
    events.append({"type": "stream_event",
                   "event": {"type": "message_stop"}})
    events.append({
        "type": "result", "is_error": False, "stop_reason": stop,
        "usage": {"input_tokens": 10, "output_tokens": 5,
                  "cache_read_input_tokens": 2},
    })
    return [json.dumps(e) for e in events]


def test_stream_yields_text_deltas_and_final_usage():
    c = ClaudeCodeClient()
    lines = _ndjson_events(text_chunks=["He", "llo, ", "world!"])
    with mock.patch("agent.claude_code_client.subprocess.Popen",
                    return_value=_FakePopen(lines)):
        chunks = list(c.chat.completions.create(
            stream=True, model="claude-haiku-4-5",
            messages=[{"role": "user", "content": "hi"}]))

    # Drop chunks with no content/tool_calls/finish_reason for the assertion
    content_parts = []
    finish_reasons = []
    usage_chunk = None
    for ch in chunks:
        if not ch.choices:
            if ch.usage:
                usage_chunk = ch
            continue
        d = ch.choices[0].delta
        if d.content:
            content_parts.append(d.content)
        if ch.choices[0].finish_reason:
            finish_reasons.append(ch.choices[0].finish_reason)

    assert "".join(content_parts) == "Hello, world!"
    assert finish_reasons == ["stop"]
    assert usage_chunk is not None
    assert usage_chunk.usage.prompt_tokens == 10
    assert usage_chunk.usage.completion_tokens == 5
    assert usage_chunk.usage.prompt_tokens_details.cached_tokens == 2


def test_stream_emits_tool_call_delta_when_text_contains_tool_call_block():
    c = ClaudeCodeClient()
    lines = _ndjson_events(tool_call={
        "id": "1", "type": "function",
        "function": {"name": "get_weather", "arguments": '{"city":"Paris"}'},
    })
    with mock.patch("agent.claude_code_client.subprocess.Popen",
                    return_value=_FakePopen(lines)):
        chunks = list(c.chat.completions.create(
            stream=True, model="claude-haiku-4-5",
            messages=[{"role": "user", "content": "weather?"}]))

    tool_call_deltas = []
    content_parts = []
    for ch in chunks:
        if not ch.choices:
            continue
        d = ch.choices[0].delta
        if d.tool_calls:
            tool_call_deltas.extend(d.tool_calls)
        if d.content:
            content_parts.append(d.content)

    assert len(tool_call_deltas) == 1
    assert tool_call_deltas[0].function.name == "get_weather"
    assert tool_call_deltas[0].function.arguments == '{"city":"Paris"}'
    # The <tool_call> body must NOT have leaked into the user-visible
    # content stream — that's the whole point of the state machine.
    assert "<tool_call>" not in "".join(content_parts)
    assert "get_weather" not in "".join(content_parts)


def test_stream_suppresses_thinking_deltas_so_chat_doesnt_show_internal_reasoning():
    """We deliberately drop thinking_delta events for claude-code so the
    WebUI doesn't render claude's internal reasoning inline in the chat."""
    c = ClaudeCodeClient()
    events = [
        {"type": "system", "subtype": "init"},
        {"type": "stream_event",
         "event": {"type": "content_block_start", "index": 0,
                   "content_block": {"type": "thinking"}}},
        {"type": "stream_event",
         "event": {"type": "content_block_delta", "index": 0,
                   "delta": {"type": "thinking_delta",
                             "thinking": "The user wants X. I should..."}}},
        {"type": "stream_event",
         "event": {"type": "content_block_start", "index": 1,
                   "content_block": {"type": "text"}}},
        {"type": "stream_event",
         "event": {"type": "content_block_delta", "index": 1,
                   "delta": {"type": "text_delta", "text": "Hello"}}},
        {"type": "result", "is_error": False, "stop_reason": "end_turn",
         "usage": {"input_tokens": 5, "output_tokens": 2}},
    ]
    lines = [json.dumps(e) for e in events]
    with mock.patch("agent.claude_code_client.subprocess.Popen",
                    return_value=_FakePopen(lines)):
        chunks = list(c.chat.completions.create(
            stream=True, model="claude-haiku-4-5",
            messages=[{"role": "user", "content": "x"}]))

    for ch in chunks:
        if not ch.choices:
            continue
        d = ch.choices[0].delta
        # No reasoning leakage in any chunk's delta.
        assert not d.reasoning_content
        assert not d.reasoning


def test_tool_result_renders_as_html_comment_not_xml_or_label():
    """Past tool results must be wrapped in HTML-comment markers (claude
    treats those as non-reproducible metadata) — NOT as <tool_result> XML
    (which claude learned to mimic and echo as <toolresult> in its replies)
    and NOT as bare `Tool:` labels (same root cause)."""
    from agent.claude_code_client import _ROLE_RENDERERS, _render_tool_result
    from agent.external_cli_shim import format_messages_as_prompt

    msgs = [
        {"role": "user", "content": "give brief"},
        {"role": "assistant", "content": "ok"},
        {"role": "tool", "name": "skill_view",
         "content": '{"linked":"morning-brief"}'},
    ]
    prompt = format_messages_as_prompt(msgs, role_renderers=_ROLE_RENDERERS)
    # New non-mimickable wrapper
    assert "<!-- jc:tool_result name=skill_view" in prompt
    assert "<!-- /jc:tool_result -->" in prompt
    # The OLD wrappers must NOT appear (regression guard against returning to
    # a format claude mimics).
    assert "<tool_result name=" not in prompt
    assert "<tool_result>" not in prompt
    assert "Tool:\n" not in prompt
    # Standalone helper round-trip
    assert _render_tool_result("X", {"name": "foo"}) == (
        "<!-- jc:tool_result name=foo (internal context — do not reproduce) -->\n"
        "X\n"
        "<!-- /jc:tool_result -->"
    )
    assert _render_tool_result("X", {}) == (
        "<!-- jc:tool_result (internal context — do not reproduce) -->\n"
        "X\n"
        "<!-- /jc:tool_result -->"
    )


def test_header_lines_include_anti_leakage_rules():
    """The system header must explicitly tell claude not to start a line
    with `<toolresult`, `<tool_result`, `Tool:`, etc. (regression guard
    against weakening the prompt)."""
    from agent.claude_code_client import _HEADER_LINES
    blob = "\n".join(_HEADER_LINES).lower()
    for marker in ("<toolresult", "<tool_result", "<!--", "tool:", "do not reproduce"):
        assert marker in blob, f"missing anti-leakage marker {marker!r} in header"


def test_stream_holds_back_partial_tool_call_open_across_chunks():
    """If `<tool_call>` straddles two text_delta chunks, the prefix must be
    held back so it isn't streamed as content."""
    c = ClaudeCodeClient()
    # Split "<tool_call>{...}</tool_call>" across chunks at "<too" | "l_call>{...}..."
    payload = '{"id":"1","type":"function","function":{"name":"x","arguments":"{}"}}'
    lines = _ndjson_events(text_chunks=[
        "<too",
        "l_call>" + payload + "</tool_call>",
    ])
    with mock.patch("agent.claude_code_client.subprocess.Popen",
                    return_value=_FakePopen(lines)):
        chunks = list(c.chat.completions.create(
            stream=True, model="claude-haiku-4-5",
            messages=[{"role": "user", "content": "x"}]))

    content_parts = []
    tcs = []
    for ch in chunks:
        if not ch.choices:
            continue
        d = ch.choices[0].delta
        if d.content:
            content_parts.append(d.content)
        if d.tool_calls:
            tcs.extend(d.tool_calls)
    # The "<too" prefix must NOT have leaked as content.
    assert "<too" not in "".join(content_parts)
    assert len(tcs) == 1 and tcs[0].function.name == "x"


def test_norm_timeout_handles_httpx_timeout_shape():
    httpx_like = SimpleNamespace(read=60, write=10, connect=5, pool=5, timeout=None)
    assert _norm_timeout(httpx_like) == 60.0
    assert _norm_timeout(30) == 30.0
    assert _norm_timeout(None) == 900.0


def test_constructor_tolerates_openai_client_kwargs():
    """The factory passes the same kwargs the OpenAI client takes — accept them quietly."""
    c = ClaudeCodeClient(
        api_key="ignored",
        base_url="claude-cli://local",
        default_headers={"X-Test": "1"},
        max_retries=3,  # unknown extra kwarg
        organization="org",  # unknown extra kwarg
    )
    assert c.api_key == "ignored"
    assert c.base_url == "claude-cli://local"
