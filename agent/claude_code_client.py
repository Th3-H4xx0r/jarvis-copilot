"""OpenAI-compatible shim that runs inference through the local ``claude`` CLI.

JarvisCopilot keeps its own agent loop and tools; ``claude -p`` is used only as
the text generator (native tools disabled via ``--tools ""``), so inference
draws on the user's Claude subscription via the CLI's own login. Mirrors
``agent/copilot_acp_client.py`` but is far simpler: one
``claude -p --output-format json`` call, prompt via stdin, single JSON result
parsed back out.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from agent.external_cli_shim import (
    extract_tool_calls_from_text as _extract_tool_calls_from_text,
    format_messages_as_prompt as _format_messages_as_prompt,
)

logger = logging.getLogger(__name__)

CLAUDE_CLI_MARKER_BASE_URL = "claude-cli://local"
_DEFAULT_TIMEOUT_SECONDS = 900.0

_HEADER_LINES = [
    "You are being used as the LLM backend for JarvisCopilot. You have NO tools of your own.",
    "IMPORTANT: If you take an action with a tool, output ONLY a <tool_call>{...}</tool_call> "
    "block with one JSON object whose keys are id/type/function{name,arguments}; "
    "arguments must be a JSON string. Do not call tools yourself — emit text only.",
    "If no tool is needed, answer the user normally as the assistant.",
]

# `claude --model` accepts full ids (e.g. "claude-opus-4-7") and short aliases
# ("opus"/"sonnet"/"haiku"). JarvisCopilot ids pass straight through; bare
# aliases stay as aliases. Empty/unknown falls back to the haiku alias so the
# silent default matches the provider profile's default_aux_model (cheap, fast).
_DEFAULT_MODEL = "haiku"


def _map_model_to_cli(model: str | None) -> str:
    m = (model or "").strip()
    if not m:
        return _DEFAULT_MODEL
    return m


def _resolve_command() -> str:
    """Resolve the ``claude`` binary, honouring env overrides."""
    return (
        os.getenv("HERMES_CLAUDE_CODE_COMMAND", "").strip()
        or os.getenv("CLAUDE_CLI_PATH", "").strip()
        or "claude"
    )


def _resolve_home_dir() -> str:
    """Return a stable HOME for the subprocess so it reads the user's ``~/.claude`` login."""
    try:
        from jarviscopilot_constants import get_subprocess_home
        h = get_subprocess_home()
        if h:
            return h
    except Exception:
        pass
    return os.environ.get("HOME", "") or os.path.expanduser("~") or "/tmp"


def _build_subprocess_env() -> dict[str, str]:
    env = os.environ.copy()
    env["HOME"] = _resolve_home_dir()
    # The parent may itself be a Claude Code session; clearing this prevents
    # the child from auto-attaching to the parent's session/IDE state.
    env.pop("CLAUDE_CODE_ENTRYPOINT", None)
    env.pop("CLAUDECODE", None)
    # Critical: scrub Anthropic API credentials from the subprocess env.
    # If ANTHROPIC_API_KEY (or related) is set in the parent, the `claude` CLI
    # will silently use API billing instead of the user's Max subscription —
    # which is exactly the behaviour this provider exists to avoid.
    for k in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_TOKEN",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    ):
        env.pop(k, None)
    return env


def _parse_claude_json(stdout: str) -> Any | None:
    """Robustly extract the single ``--output-format json`` object from stdout.

    The CLI is documented to emit exactly one JSON object, but in practice it
    may print log/warning lines (auto-update notices, etc.) before or after
    that object. We:

      1. Try a plain ``json.loads`` of the full stdout (the happy path).
      2. Failing that, scan lines from the bottom and try each — the result
         object is normally the last non-empty line.
      3. Failing that, return None so the caller can surface the raw stdout.
    """
    text = (stdout or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        pass
    for line in reversed(text.splitlines()):
        s = line.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            return json.loads(s)
        except Exception:
            continue
    return None


def _norm_timeout(timeout: Any, default: float = _DEFAULT_TIMEOUT_SECONDS) -> float:
    """Accept an int/float or an ``httpx.Timeout``-shaped object."""
    if timeout is None:
        return default
    if isinstance(timeout, (int, float)):
        return float(timeout)
    cands = [getattr(timeout, a, None) for a in ("read", "write", "connect", "pool", "timeout")]
    nums = [float(v) for v in cands if isinstance(v, (int, float))]
    return max(nums) if nums else default


class _CCChatCompletions:
    def __init__(self, client: "ClaudeCodeClient") -> None:
        self._c = client

    def create(self, **kwargs: Any) -> Any:
        return self._c._create_chat_completion(**kwargs)


class _CCChatNamespace:
    def __init__(self, client: "ClaudeCodeClient") -> None:
        self.completions = _CCChatCompletions(client)


class ClaudeCodeClient:
    """Minimal OpenAI-client-compatible facade over the local ``claude`` CLI.

    Exposes the surface the rest of JarvisCopilot expects from an inference
    client (``.api_key``, ``.base_url``, ``.chat.completions.create(...)``,
    ``.close()``) but executes each request as a single ``claude -p`` invocation
    that returns a JSON ``result`` we parse for content + ``<tool_call>``
    blocks + usage.
    """

    def __init__(
        self,
        *,
        api_key: str | None = None,
        base_url: str | None = None,
        command: str | None = None,
        args: list[str] | None = None,
        cwd: str | None = None,
        timeout: float | None = None,
        default_headers: dict[str, str] | None = None,
        **_: Any,
    ) -> None:
        self.api_key = api_key or "claude-code"
        self.base_url = base_url or CLAUDE_CLI_MARKER_BASE_URL
        self._command = command or _resolve_command()
        self._extra_args = list(args or [])
        # Use a neutral, trusted cwd: the user's HOME avoids pulling in any
        # project-local CLAUDE.md / MCP / hooks (further reinforced by
        # --setting-sources "" and --strict-mcp-config in _build_argv).
        self._cwd = str(Path(cwd or _resolve_home_dir()).resolve())
        self._timeout = timeout
        # default_headers is accepted for API-compatibility with the OpenAI
        # client constructor but has no meaning for a CLI subprocess.
        self._default_headers = dict(default_headers or {})
        self.chat = _CCChatNamespace(self)
        self.is_closed = False

    def close(self) -> None:
        self.is_closed = True

    # --- internals ----------------------------------------------------------

    def _build_argv(self, model: str | None) -> list[str]:
        return [
            self._command,
            "-p",
            "--tools", "",                        # disable all native tools → pure text gen
            "--output-format", "json",            # single JSON object on stdout
            "--model", _map_model_to_cli(model),
            "--setting-sources", "",              # skip user/project/local settings
            "--strict-mcp-config",                # ignore global MCP config
            "--no-session-persistence",           # one-shot
            *self._extra_args,
        ]

    def _create_chat_completion(
        self,
        *,
        model: str | None = None,
        messages: list[dict[str, Any]] | None = None,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any = None,
        timeout: Any = None,
        **_: Any,
    ) -> Any:
        prompt = _format_messages_as_prompt(
            messages or [],
            model=model,
            tools=tools,
            tool_choice=tool_choice,
            header_lines=_HEADER_LINES,
        )
        eff_timeout = _norm_timeout(timeout if timeout is not None else self._timeout)
        argv = self._build_argv(model)

        try:
            cp = subprocess.run(
                argv,
                input=prompt,
                capture_output=True,
                text=True,
                timeout=eff_timeout,
                cwd=self._cwd,
                env=_build_subprocess_env(),
            )
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Could not start the Claude Code CLI ('{self._command}'). "
                "Install Claude Code and run `claude` to log in to your Claude "
                "subscription, or set HERMES_CLAUDE_CODE_COMMAND."
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"Claude Code CLI timed out after {eff_timeout:.0f}s."
            ) from exc

        stdout = (cp.stdout or "").strip()
        stderr = (cp.stderr or "").strip()

        if not stdout:
            if cp.returncode != 0:
                raise RuntimeError(
                    f"Claude Code CLI exited with code {cp.returncode}. "
                    f"stderr: {stderr[:500]}"
                )
            raise RuntimeError(
                f"Claude Code CLI produced no output. stderr: {stderr[:500]}"
            )

        data = _parse_claude_json(stdout)
        if data is None:
            raise RuntimeError(
                f"Claude Code CLI returned non-JSON output: {stdout[:500]}"
            )

        if isinstance(data, dict) and data.get("is_error"):
            msg = data.get("result") or data.get("error") or stderr or "unknown error"
            raise RuntimeError(f"Claude Code error: {msg}")
        if not isinstance(data, dict):
            raise RuntimeError(
                f"Claude Code CLI returned unexpected JSON shape: {str(data)[:500]}"
            )

        result_text = data.get("result") or ""
        tool_calls, cleaned = _extract_tool_calls_from_text(result_text)

        usage_in = data.get("usage") or {}
        prompt_toks = int(usage_in.get("input_tokens") or 0)
        completion_toks = int(usage_in.get("output_tokens") or 0)
        cached = int(usage_in.get("cache_read_input_tokens") or 0)
        usage = SimpleNamespace(
            prompt_tokens=prompt_toks,
            completion_tokens=completion_toks,
            total_tokens=prompt_toks + completion_toks,
            prompt_tokens_details=SimpleNamespace(cached_tokens=cached),
        )

        message = SimpleNamespace(
            content=cleaned if cleaned else None,
            tool_calls=tool_calls,
            reasoning=None,
            reasoning_content=None,
            reasoning_details=None,
        )
        finish_reason = "tool_calls" if tool_calls else "stop"
        choice = SimpleNamespace(message=message, finish_reason=finish_reason)
        return SimpleNamespace(
            choices=[choice],
            usage=usage,
            model=model or "claude-code",
        )
