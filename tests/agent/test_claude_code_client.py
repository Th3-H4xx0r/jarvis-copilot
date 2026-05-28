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
