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
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from agent.external_cli_shim import (
    build_stream_json_user_input as _build_stream_json_user_input,
    extract_image_blocks as _extract_image_blocks,
    extract_tool_calls_from_text as _extract_tool_calls_from_text,
    filter_repeat_tool_calls as _filter_repeat_tool_calls,
    format_messages_as_prompt as _format_messages_as_prompt,
    sanitize_model_text as _sanitize_model_text,
)

logger = logging.getLogger(__name__)

CLAUDE_CLI_MARKER_BASE_URL = "claude-cli://local"
_DEFAULT_TIMEOUT_SECONDS = 900.0

def _render_tool_result(content: str, message: dict[str, Any]) -> str:
    """Wrap a past tool result in an HTML comment block.

    Earlier iterations used <tool_result name="…">…</tool_result>, but claude
    treated that as a generatable element and started echoing
    ``<toolresult name="executecode">{...}</toolresult>`` blocks as part of
    its own response. HTML comments are conventionally metadata — claude's
    training strongly biases against reproducing them as visible output, and
    pairing them with explicit "never write a line starting with <!--"
    instructions in the header neutralises the mimicry.
    """
    tool_name = ""
    if isinstance(message, dict):
        tool_name = str(message.get("name") or "").strip()
    name_attr = f" name={tool_name}" if tool_name else ""
    return (
        f"<!-- jc:tool_result{name_attr} (internal context — do not reproduce) -->\n"
        f"{content}\n"
        f"<!-- /jc:tool_result -->"
    )


_ROLE_RENDERERS = {"tool": _render_tool_result}


_HEADER_LINES = [
    "You are being used as the LLM backend for JarvisCopilot. You have NO tools of your own.",
    "If you take an action with a tool, output ONLY a <tool_call>{...}</tool_call> "
    "block with one JSON object whose keys are id/type/function{name,arguments}; "
    "arguments must be a JSON string. Do not call tools yourself — emit text only.",
    "If no tool is needed, answer the user normally as the assistant.",
    "Each tool RESULT in the transcript is prefixed `(result of `X` — you "
    "already called it; do NOT call `X` again)`. That is history: NEVER re-issue "
    "a tool that already has a result (doing so loops forever). Use the results "
    "to proceed, and once the request is satisfied give one final answer with NO "
    "tool call.",
    "To CALL a tool you MUST emit a real <tool_call>{...}</tool_call> block — "
    "that is the ONLY thing that runs a tool. NEVER write a `(result of …)` note "
    "or any history line yourself; writing one runs nothing.",
    # CRITICAL anti-leakage rules. Past tool results appear in the transcript
    # inside HTML-comment markers (`<!-- jc:tool_result … -->`) so claude
    # treats them as metadata, not as a format to mimic. These rules MUST be
    # restated because claude has historically still echoed them otherwise.
    "CRITICAL — anti-leakage rules (do not reproduce internal context):",
    "  1. Lines beginning with `<!--` and ending with `-->` are INTERNAL "
    "metadata (tool results, system markers). Do not reproduce them in your "
    "reply, in any form.",
    "  2. NEVER start a line of your reply with `<!--`, `<tool_result`, "
    "`<toolresult`, `<tool`, `[tool`, `Tool:`, `User:`, `Assistant:`, or "
    "`System:` — those are transcript labels, not output.",
    "  3. NEVER paste, quote, summarize-as-JSON, or describe the raw stdout/"
    "stderr/JSON content of past tool results. JarvisCopilot already shows "
    "them to the user as separate UI elements; reproducing them is "
    "redundant noise.",
    "  4. Your reply must be natural, conversational text directed at the "
    "user — what you observed, what you're doing next, or your final answer.",
    "Examples of WRONG output (DO NOT do this):",
    "  • `<toolresult>{\"stdout\":\"...\"}</toolresult>`",
    "  • `Tool: {\"result\": ...}`",
    "  • `<!-- jc:tool_result name=execute_code --> {...} <!-- /jc:tool_result -->`",
    "Examples of CORRECT output:",
    "  • `The weather is 68°F, partly cloudy.`",
    "  • `Done — the event is on your calendar.`",
    "  • `I'll check your iPhone's available shortcuts next.` <tool_call>{...}</tool_call>",
]

# `claude --model` accepts full ids (e.g. "claude-opus-4-7") and short aliases
# ("opus"/"sonnet"/"haiku"). JarvisCopilot ids pass straight through; bare
# aliases stay as aliases. Empty/unknown falls back to the haiku alias so the
# silent default matches the provider profile's default_aux_model (cheap, fast).
_DEFAULT_MODEL = "haiku"
_CLI_ALIASES = {"opus", "sonnet", "haiku"}
_LOGGED_NON_CLAUDE_MODELS: set[str] = set()


def _looks_like_claude_model(name: str) -> bool:
    """True when ``name`` is something the `claude --model` flag understands."""
    n = (name or "").strip().lower()
    if not n:
        return False
    if n in _CLI_ALIASES:
        return True
    # Anthropic model ids historically start with ``claude-``. Future
    # families that don't would need to be added here; we accept the
    # well-known prefix as the canonical signal.
    return n.startswith("claude-")


def _map_model_to_cli(model: str | None) -> str:
    """Map a JarvisCopilot model id to the value passed via `claude --model`.

    If the caller passes a model that doesn't look like a claude model
    (e.g. ``gpt-5.5`` from a stale auxiliary / delegate-subagent config that
    hasn't been re-pointed since the user switched the main provider to
    claude-code), fall back to the default claude model rather than letting
    the CLI reject the request. We log a single warning per session per bad
    model so the user can fix the config without drowning in repeats.
    """
    m = (model or "").strip()
    if not m:
        return _DEFAULT_MODEL
    if _looks_like_claude_model(m):
        return m
    if m not in _LOGGED_NON_CLAUDE_MODELS:
        _LOGGED_NON_CLAUDE_MODELS.add(m)
        logger.warning(
            "claude-code: received non-claude model %r — falling back to %r. "
            "This usually means an auxiliary or delegate-subagent config "
            "still references the previous provider's model id. Re-run "
            "`jarviscopilot model` to update, or set the relevant "
            "`auxiliary.<task>.model` in config.yaml.",
            m, _DEFAULT_MODEL,
        )
    return _DEFAULT_MODEL


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


def _resolve_injected_oauth_token() -> str | None:
    """Resolve a JarvisCopilot-managed Claude Code subscription token, if any.

    Order: an explicit per-deployment override env var, then the setup-token
    stored in the active profile's credential pool. Returns None when neither
    is present (the CLI then falls back to its own ``~/.claude`` file login).
    """
    tok = os.getenv("HERMES_CLAUDE_CODE_OAUTH_TOKEN", "").strip()
    if tok:
        return tok
    try:
        from jarviscopilot_cli.auth import resolve_claude_code_oauth_token
        stored = resolve_claude_code_oauth_token()
        if stored:
            return stored.strip()
    except Exception:
        # Auth store unavailable (e.g. import/profile error) — fall back to
        # the CLI's own login rather than failing the request.
        logger.debug("claude-code: could not resolve a managed setup-token", exc_info=True)
    return None


def _build_subprocess_env() -> dict[str, str]:
    env = os.environ.copy()
    env["HOME"] = _resolve_home_dir()
    # The parent may itself be a Claude Code session; clearing this prevents
    # the child from auto-attaching to the parent's session/IDE state.
    env.pop("CLAUDE_CODE_ENTRYPOINT", None)
    env.pop("CLAUDECODE", None)
    # Critical: always scrub raw-API billing credentials. If ANTHROPIC_API_KEY
    # (or the bedrock/vertex switches) reaches the CLI it silently bills the
    # rate-limited API path — the "out of extra usage" route this provider
    # exists to avoid.
    for k in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_TOKEN",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    ):
        env.pop(k, None)
    # Subscription auth. A JarvisCopilot-managed setup-token (from
    # `claude setup-token`, stored in the credential pool) is a *subscription*
    # OAuth token: injecting it as CLAUDE_CODE_OAUTH_TOKEN bills the Claude Code
    # subscription path, not the API, and survives container redeploys. It is
    # injected ONLY into this subprocess. Without a managed token we scrub any
    # ambient value and let `claude` use its own ~/.claude file login (the
    # proven default on the server).
    token = _resolve_injected_oauth_token()
    if token:
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    else:
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
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

    def _build_argv(
        self, model: str | None, *, stream: bool = False, input_stream_json: bool = False
    ) -> list[str]:
        argv = [
            self._command,
            "-p",
            "--tools", "",                        # disable all native tools → pure text gen
            "--output-format", "stream-json" if stream else "json",
            "--model", _map_model_to_cli(model),
            "--setting-sources", "",              # skip user/project/local settings
            "--strict-mcp-config",                # ignore global MCP config
            "--no-session-persistence",           # one-shot
        ]
        if input_stream_json:
            # Vision path: stdin carries a JSON user turn with image blocks
            # rather than plain text (see _build_stream_json_user_input).
            argv += ["--input-format", "stream-json"]
        if stream:
            # --include-partial-messages emits content_block_delta events as the
            # model generates; --verbose is required alongside --print for the
            # full stream-event firehose.
            argv += ["--include-partial-messages", "--verbose"]
        argv += list(self._extra_args)
        return argv

    def _create_chat_completion(
        self,
        *,
        model: str | None = None,
        messages: list[dict[str, Any]] | None = None,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any = None,
        timeout: Any = None,
        stream: bool = False,
        **_: Any,
    ) -> Any:
        if stream:
            return self._stream_chat_completion(
                model=model, messages=messages, tools=tools,
                tool_choice=tool_choice, timeout=timeout,
            )
        prompt = _format_messages_as_prompt(
            messages or [],
            model=model,
            tools=tools,
            tool_choice=tool_choice,
            header_lines=_HEADER_LINES,
            role_renderers=_ROLE_RENDERERS,
        )
        eff_timeout = _norm_timeout(timeout if timeout is not None else self._timeout)
        # Vision: when the conversation carries images, send a stream-json user
        # turn (text + base64 image blocks) instead of the plain-text prompt.
        # Text-only requests keep the proven plain-stdin path untouched.
        image_blocks = _extract_image_blocks(messages or [])
        if image_blocks:
            stdin_payload = _build_stream_json_user_input(prompt, image_blocks)
            argv = self._build_argv(model, input_stream_json=True)
        else:
            stdin_payload = prompt
            argv = self._build_argv(model)

        try:
            cp = subprocess.run(
                argv,
                input=stdin_payload,
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
        # Deterministic loop-breaker: if every call is an exact repeat of one
        # already executed in this conversation, drop them so the turn ends.
        tool_calls = _filter_repeat_tool_calls(tool_calls, messages or [])
        # Strip any internal scaffolding the model echoed into its visible reply.
        cleaned = _sanitize_model_text(cleaned)

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

    # ─── Streaming ────────────────────────────────────────────────────────
    #
    # ``claude -p --output-format stream-json --include-partial-messages``
    # emits NDJSON events:
    #   {"type":"stream_event", "event":{"type":"content_block_delta",
    #       "delta":{"type":"text_delta", "text":"PONG"}}}
    #   {"type":"stream_event", "event":{"type":"content_block_delta",
    #       "delta":{"type":"thinking_delta", "thinking":"..."}}}
    #   {"type":"assistant", "message":{...}}
    #   {"type":"result", "stop_reason":"end_turn", "usage":{...}}
    #
    # We translate those into the OpenAI streaming-chunk shape the agent's
    # interruptible_streaming_api_call expects (chunk.choices[0].delta with
    # .content/.tool_calls/.reasoning_content/.reasoning, plus a final
    # empty-choices chunk carrying usage).
    #
    # Tool calls: because --tools "" disables claude's native tools, claude
    # emits our instructed `<tool_call>{...}</tool_call>` block as plain text.
    # A small state machine intercepts that — pre-tag text streams as content,
    # the tag body buffers, and the parsed call is emitted in one tool-call
    # delta. A short held-back buffer handles `<tool_call>` opens that
    # straddle chunk boundaries.

    def _stream_chat_completion(
        self,
        *,
        model: str | None = None,
        messages: list[dict[str, Any]] | None = None,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any = None,
        timeout: Any = None,
    ):
        prompt = _format_messages_as_prompt(
            messages or [],
            model=model,
            tools=tools,
            tool_choice=tool_choice,
            header_lines=_HEADER_LINES,
            role_renderers=_ROLE_RENDERERS,
        )
        eff_timeout = _norm_timeout(timeout if timeout is not None else self._timeout)
        # Vision: same stream-json INPUT switch as the non-streaming path.
        image_blocks = _extract_image_blocks(messages or [])
        if image_blocks:
            prompt = _build_stream_json_user_input(prompt, image_blocks)
            argv = self._build_argv(model, stream=True, input_stream_json=True)
        else:
            argv = self._build_argv(model, stream=True)

        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd=self._cwd,
                env=_build_subprocess_env(),
            )
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Could not start the Claude Code CLI ('{self._command}'). "
                "Install Claude Code and run `claude` to log in to your Claude "
                "subscription, or set HERMES_CLAUDE_CODE_COMMAND."
            ) from exc

        # Send the prompt and close stdin so claude knows it has the full input.
        try:
            if proc.stdin is not None:
                proc.stdin.write(prompt)
                proc.stdin.close()
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
            raise

        model_name = model or "claude-code"

        def _build_chunk(*, content=None, tool_calls=None, finish_reason=None):
            delta = SimpleNamespace(
                content=content,
                tool_calls=tool_calls,
                reasoning_content=None,
                reasoning=None,
            )
            return SimpleNamespace(
                choices=[SimpleNamespace(index=0, delta=delta, finish_reason=finish_reason)],
                model=model_name,
                usage=None,
            )

        # Buffer the whole generation, then extract tool calls + sanitise the
        # content in ONE pass — exactly like the non-streaming path. This is
        # deliberately NOT token-incremental: the model can echo leaked
        # transcript scaffolding (tool-result markers, role labels, raw tool
        # JSON) mid-stream, and only the COMPLETE text can be cleaned without
        # (a) showing the leak before we can classify it, or (b) dropping a real
        # <tool_call> that appears after a leaked marker. claude-code replies are
        # short and fast, so the latency cost is negligible.
        text_parts: list[str] = []
        usage_event: dict[str, Any] = {}
        raw_stop = "end_turn"
        got_result = False
        try:
            assert proc.stdout is not None
            start_time = time.monotonic()
            for raw_line in proc.stdout:
                # Coarse wall-clock cap; the agent has its own stall detection.
                if time.monotonic() - start_time > eff_timeout:
                    raise RuntimeError(
                        f"Claude Code CLI streaming timed out after {eff_timeout:.0f}s."
                    )
                line = (raw_line or "").strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except Exception:
                    continue
                etype = event.get("type")
                if etype == "result" and event.get("is_error"):
                    msg = event.get("result") or event.get("error") or "unknown error"
                    raise RuntimeError(f"Claude Code error: {msg}")
                if etype == "assistant":
                    m = (event.get("message") or {}).get("model")
                    if m:
                        model_name = m
                    continue
                if etype == "stream_event":
                    sub = event.get("event") or {}
                    if sub.get("type") == "content_block_delta":
                        d = sub.get("delta") or {}
                        # thinking_delta / signature_delta are never displayed.
                        if d.get("type") == "text_delta":
                            t = d.get("text") or ""
                            if t:
                                text_parts.append(t)
                    continue
                if etype == "result":
                    usage_event = event.get("usage") or {}
                    raw_stop = event.get("stop_reason") or "end_turn"
                    got_result = True
                    break
        finally:
            try:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=2.0)
                    except Exception:
                        proc.kill()
            except Exception:
                pass

        if not got_result and not text_parts:
            # Process died mid-stream with no output — surface it.
            stderr_tail = ""
            try:
                if proc.stderr is not None:
                    stderr_tail = (proc.stderr.read() or "").strip()[:500]
            except Exception:
                pass
            raise RuntimeError(
                f"Claude Code CLI stream ended unexpectedly. stderr: {stderr_tail}"
            )

        full_text = "".join(text_parts)
        tool_calls, cleaned = _extract_tool_calls_from_text(full_text)
        tool_calls = _filter_repeat_tool_calls(tool_calls, messages or [])
        cleaned = _sanitize_model_text(cleaned)

        if cleaned:
            yield _build_chunk(content=cleaned)

        for idx, tc in enumerate(tool_calls):
            fn = getattr(tc, "function", None)
            name = getattr(fn, "name", "") if fn is not None else ""
            args = getattr(fn, "arguments", "{}") if fn is not None else "{}"
            if not isinstance(args, str):
                args = json.dumps(args, ensure_ascii=False)
            call_id = getattr(tc, "id", None) or f"cli_call_{idx + 1}"
            yield _build_chunk(tool_calls=[SimpleNamespace(
                index=idx, id=call_id, type="function",
                function=SimpleNamespace(name=name, arguments=args),
                extra_content=None,
            )])

        finish = "tool_calls" if tool_calls else _STOP_REASON_TO_FINISH.get(raw_stop, "stop")
        yield _build_chunk(finish_reason=finish)

        prompt_toks = int(usage_event.get("input_tokens") or 0)
        completion_toks = int(usage_event.get("output_tokens") or 0)
        cached = int(usage_event.get("cache_read_input_tokens") or 0)
        usage = SimpleNamespace(
            prompt_tokens=prompt_toks,
            completion_tokens=completion_toks,
            total_tokens=prompt_toks + completion_toks,
            prompt_tokens_details=SimpleNamespace(cached_tokens=cached),
        )
        yield SimpleNamespace(choices=[], usage=usage, model=model_name)


# Map claude stop_reasons to OpenAI finish_reasons (mirrors
# agent/transports/anthropic.py:_STOP_REASON_MAP so downstream code stays
# consistent across the two Claude paths).
_STOP_REASON_TO_FINISH = {
    "end_turn": "stop",
    "tool_use": "tool_calls",
    "max_tokens": "length",
    "stop_sequence": "stop",
    "refusal": "content_filter",
    "model_context_window_exceeded": "length",
}


