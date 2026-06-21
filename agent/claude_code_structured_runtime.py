"""Runtime glue that routes a live ``claude-code`` turn through the STRUCTURED MCP
engine (``HERMES_CLAUDE_CODE_STRUCTURED=1``).

Why
---
The text-shim drives claude with ``claude -p --tools ""`` and parses
``<tool_call>{...}</tool_call>`` text. Its fatal weakness: when the model emits a
prose turn ("Right away — let me read the file…") with NO ``<tool_call>``, JC's
agent loop sees ``finish_reason="stop"`` and ENDS — the task is silently
abandoned (``0 in · 17 out``, "done in 6s", nothing actually done). codex never
does this because it is *structured*: typed ``function_call`` items force the loop
to continue until a real final answer.

This module makes claude-code behave the same way. ``claude`` exposes JarvisCopilot's
own tools as native MCP ``tool_use`` (via :mod:`agent.claude_code_mcp_bridge`),
DRIVES the whole task itself, and blocks on each tool until JC returns a result —
so a "let me read X" turn becomes an actual structured tool call, not abandoned
prose.

Seam
----
:func:`run_claude_structured_response` is called from
``interruptible_api_call`` / ``interruptible_streaming_api_call`` (in
``agent/chat_completion_helpers.py``) when :func:`should_use_structured` is true.
It runs the entire turn, executing each tool via ``agent._invoke_tool`` (the same
single-tool path the concurrent executor uses — full tool coverage + correct
session/memory context) with live text streaming + tool-status callbacks, then
returns ONE OpenAI-shaped response (``finish_reason="stop"``, no ``tool_calls``)
so the rest of the agent loop is unchanged.
"""
from __future__ import annotations

import json
import threading
import uuid
from types import SimpleNamespace
from typing import Any

from agent.claude_code_structured import run_structured_turn, structured_enabled


class StructuredTurnFailed(RuntimeError):
    """A structured turn hard-failed BEFORE streaming anything to the user, so the
    caller can safely fall back to the text-shim for this turn (no duplicate
    output). Distinct from a mid-stream failure, which must surface as-is."""

# A short, fixed --system-prompt. The agent's REAL system prompt (identity, skills,
# memory) and the conversation history are folded into the stdin user text instead
# (see _build_user_text) — keeping --system-prompt tiny avoids ARG_MAX limits, the
# same reason the text-shim sends everything over stdin.
_STRUCTURED_SYSTEM = (
    "You are the model backend for JarvisCopilot. Use the tools available to you "
    "to fully complete the user's request, then give a concise final answer."
)

# Preamble folded into the stdin user text. No `<tool_call>` DSL — tools are now
# native (MCP) tool_use, so the model just calls them. Keeps the autonomy +
# anti-leakage guidance that matters for clean, complete replies.
_STRUCTURED_HEADER_LINES = [
    "You are the model backend for JarvisCopilot. You have a set of TOOLS available "
    "to you (provided natively) — call them directly to take actions; do not narrate "
    "tool calls as text.",
    "Work AUTONOMOUSLY to completion. If you decide to do something (\"Now I'll…\", "
    "\"Let me…\", \"Next I'll…\"), actually CALL the tool in the same turn — never "
    "stop just to report a plan or ask whether to continue. Keep calling tools until "
    "the WHOLE request is done, and only THEN give a final answer.",
    "Earlier tool results appear in the transcript as internal context. NEVER re-run "
    "a tool that already has a result, and never paste, quote, or re-serialize raw "
    "tool stdout/JSON back to the user — JarvisCopilot already shows those as separate "
    "UI elements.",
    "Your visible reply must be natural, conversational text directed at the user: "
    "what you found, what you did, or your final answer. Do not emit transcript "
    "labels (User:/Assistant:/Tool:) or internal markers.",
]


def _turn_has_images(api_kwargs: dict | None) -> bool:
    if not api_kwargs:
        return False
    try:
        from agent.external_cli_shim import extract_image_blocks
        return bool(extract_image_blocks(api_kwargs.get("messages") or []))
    except Exception:
        return False


def should_use_structured(agent: Any, api_kwargs: dict | None = None) -> bool:
    """True when this agent is the claude-code provider AND the structured engine
    is enabled — the only case routed through the MCP driver.

    Vision turns are deliberately EXCLUDED: the structured stdin user message only
    carries text, so images would be silently dropped. Those fall back to the
    text-shim's dedicated vision path (stream-json input with image blocks), which
    already works. Structured handles every text/tool-driven turn.
    """
    try:
        if getattr(agent, "provider", "") != "claude-code" or not structured_enabled():
            return False
        if _turn_has_images(api_kwargs):
            return False
        return True
    except Exception:
        return False


def _render_content(content: Any) -> str:
    from agent.external_cli_shim import render_message_content
    try:
        return render_message_content(content)
    except Exception:
        return "" if content is None else str(content)


def _build_user_text(messages: list[dict[str, Any]], model: str | None) -> str:
    """Fold the system prompt + full conversation into ONE stdin text blob — the
    same proven flattening the text-shim uses, minus the `<tool_call>` DSL header
    (tools are native here). System turns are inlined so the agent's real system
    prompt travels over stdin, not as a giant --system-prompt argv."""
    from agent.external_cli_shim import format_messages_as_prompt
    from agent.claude_code_client import _ROLE_RENDERERS

    system_parts: list[str] = []
    convo: list[dict[str, Any]] = []
    for m in messages or []:
        if isinstance(m, dict) and m.get("role") == "system":
            rendered = _render_content(m.get("content"))
            if rendered.strip():
                system_parts.append(rendered)
        else:
            convo.append(m)

    body = format_messages_as_prompt(
        convo,
        model=model,
        tools=None,            # tools are exposed via MCP, not embedded as text
        tool_choice=None,
        header_lines=_STRUCTURED_HEADER_LINES,
        role_renderers=_ROLE_RENDERERS,
    )
    if system_parts:
        sys_text = "\n\n".join(system_parts)
        return f"<system>\n{sys_text}\n</system>\n\n{body}"
    return body


def _args_preview(args: dict[str, Any]) -> str:
    try:
        s = json.dumps(args, ensure_ascii=False)
    except Exception:
        s = str(args)
    return s[:200]


def _looks_like_error_result(result: str) -> bool:
    """Best-effort: did a tool return a JSON error envelope? Used only to label the
    progress UI (is_error) accurately — never to alter the result the model sees."""
    s = (result or "").lstrip()
    if not s.startswith("{"):
        return False
    try:
        obj = json.loads(s)
    except Exception:
        return False
    return isinstance(obj, dict) and (
        bool(obj.get("error")) or obj.get("success") is False
    )


def run_claude_structured_response(agent: Any, api_kwargs: dict, *, on_first_delta=None) -> Any:
    """Drive one claude-code turn via the structured MCP engine and return an
    OpenAI-shaped response (``choices[0].message`` with ``content`` + empty
    ``tool_calls``, ``finish_reason="stop"``). Tools are executed inline through
    ``agent._invoke_tool``; assistant text streams live via ``_fire_stream_delta``.
    """
    from agent.claude_code_client import _map_model_to_cli, _resolve_command

    messages = api_kwargs.get("messages") or []
    tools = api_kwargs.get("tools") or []
    model = api_kwargs.get("model")

    user_text = _build_user_text(messages, model)
    # The conversation loop stamps the active task id here (run BEFORE any tool
    # dispatch) so the executor scopes tool env/state to the right task.
    effective_task_id = getattr(agent, "_current_task_id", None) or ""

    first = {"done": False}
    streamed = {"any": False}

    def _fire_first() -> None:
        if not first["done"] and on_first_delta is not None:
            first["done"] = True
            try:
                on_first_delta()
            except Exception:
                pass

    def _on_text(text: str) -> None:
        _fire_first()
        if text:
            streamed["any"] = True
        try:
            agent._fire_stream_delta(text)
        except Exception:
            pass

    # Serialize tool execution: claude can request several tool_use blocks and the
    # bridge runs each in a pool thread, but JC's loop state (status, _current_tool)
    # assumes one tool at a time — mirror that here.
    exec_lock = threading.Lock()

    def _execute_tool(name: str, args: dict[str, Any]) -> str:
        with exec_lock:
            tcid = "call_" + uuid.uuid4().hex[:24]
            # Register this bridge-pool worker so a user interrupt fans out to it
            # (the main loop thread is parked reading the CLI's stdout, so the tool
            # runs here, not there). Mirrors tool_executor's worker registration.
            worker_tid = threading.current_thread().ident
            tracker = getattr(agent, "_tool_worker_threads", None)
            tracker_lock = getattr(agent, "_tool_worker_threads_lock", None)
            if tracker is not None and tracker_lock is not None:
                try:
                    with tracker_lock:
                        tracker.add(worker_tid)
                    if getattr(agent, "_interrupt_requested", False):
                        agent._set_interrupt(True, worker_tid)
                except Exception:
                    pass
            errored = False
            try:
                _fire_first()
                agent._current_tool = name
                try:
                    agent._fire_tool_gen_started(name)
                except Exception:
                    pass
                if getattr(agent, "tool_progress_callback", None):
                    try:
                        agent.tool_progress_callback("tool.started", name, _args_preview(args), args)
                    except Exception:
                        pass
                if getattr(agent, "tool_start_callback", None):
                    try:
                        agent.tool_start_callback(tcid, name, args)
                    except Exception:
                        pass
                try:
                    agent._touch_activity(f"executing tool: {name}")
                except Exception:
                    pass
            except Exception:
                pass

            try:
                result = agent._invoke_tool(name, args, effective_task_id, tool_call_id=tcid, messages=None)
            except Exception as exc:
                errored = True
                result = json.dumps({"error": f"tool '{name}' failed: {exc}"}, ensure_ascii=False)
            result = "" if result is None else (result if isinstance(result, str) else str(result))
            if not errored and _looks_like_error_result(result):
                errored = True

            try:
                if getattr(agent, "tool_progress_callback", None):
                    try:
                        agent.tool_progress_callback(
                            "tool.completed", name, None, None,
                            duration=0.0, is_error=errored, result=result,
                        )
                    except Exception:
                        pass
                if getattr(agent, "tool_complete_callback", None):
                    try:
                        agent.tool_complete_callback(tcid, name, args, result)
                    except Exception:
                        pass
                agent._current_tool = None
                # Make the next streamed text start a new paragraph so prose that
                # resumes after a tool call doesn't run into the pre-call text
                # ("…now.It's…"). _fire_stream_delta consumes this flag once.
                try:
                    agent._stream_needs_break = True
                except Exception:
                    pass
                try:
                    agent._touch_activity(f"tool completed: {name}")
                except Exception:
                    pass
            except Exception:
                pass
            # Unregister this worker tid (paired with the add above). Reached on
            # every path — the body's operations are all individually guarded.
            if tracker is not None and tracker_lock is not None:
                try:
                    with tracker_lock:
                        tracker.discard(worker_tid)
                except Exception:
                    pass
            return result

    has_consumers = False
    try:
        has_consumers = bool(agent._has_stream_consumers())
    except Exception:
        has_consumers = False

    res = run_structured_turn(
        user_text=user_text,
        tools=tools,
        execute_tool=_execute_tool,
        command=_resolve_command(),
        model_cli=_map_model_to_cli(model),
        system_prompt=_STRUCTURED_SYSTEM,
        on_text=_on_text if has_consumers else None,
        should_abort=lambda: bool(getattr(agent, "_interrupt_requested", False)),
    )

    if getattr(agent, "_interrupt_requested", False):
        raise InterruptedError("Agent interrupted during claude-code structured turn")

    text = (res.text or "").strip()
    if res.is_error and not text:
        msg = f"claude-code structured turn failed: {res.error or 'unknown error'}"
        # Nothing reached the user yet → let the caller retry on the text-shim
        # rather than hard-failing the turn (e.g. an environment/CLI issue).
        if not streamed["any"]:
            raise StructuredTurnFailed(msg)
        raise RuntimeError(msg)

    u = res.usage or {}
    prompt_toks = int(u.get("input_tokens") or 0)
    completion_toks = int(u.get("output_tokens") or 0)
    cached = int(u.get("cache_read_input_tokens") or 0)
    usage = SimpleNamespace(
        prompt_tokens=prompt_toks,
        completion_tokens=completion_toks,
        total_tokens=prompt_toks + completion_toks,
        prompt_tokens_details=SimpleNamespace(cached_tokens=cached),
    )
    message = SimpleNamespace(
        content=text or None,
        tool_calls=[],
        reasoning=None,
        reasoning_content=None,
        reasoning_details=None,
    )
    choice = SimpleNamespace(message=message, finish_reason="stop")
    return SimpleNamespace(choices=[choice], usage=usage, model=model or "claude-code")
