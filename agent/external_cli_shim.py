"""Shared helpers for external-CLI inference shims.

Both the GitHub Copilot ACP client (``agent/copilot_acp_client.py``) and the
Claude Code CLI client (``agent/claude_code_client.py``) use an external agent
process purely as a *text generator*: JarvisCopilot keeps its own agent loop and
tools, formats the conversation + tool schemas into one prompt that instructs
``<tool_call>{...}</tool_call>`` emission, and parses tool calls back out of the
returned text.

This module owns that prompt format and the tool-call parser so the two clients
stay byte-identical and are tested once. The ``header_lines`` argument lets each
backend supply its own preamble while sharing the transcript/tool-spec rendering
and parsing.
"""

from __future__ import annotations

import json
import re
from types import SimpleNamespace
from typing import Any

_TOOL_CALL_BLOCK_RE = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.DOTALL)
_TOOL_CALL_JSON_RE = re.compile(
    r"\{\s*\"id\"\s*:\s*\"[^\"]+\"\s*,\s*\"type\"\s*:\s*\"function\"\s*,\s*\"function\"\s*:\s*\{.*?\}\s*\}",
    re.DOTALL,
)

# Generic preamble used when a backend doesn't supply its own ``header_lines``.
_DEFAULT_HEADER_LINES = [
    "You are being used as the LLM backend for JarvisCopilot.",
    "IMPORTANT: If you take an action with a tool, you MUST output tool calls "
    "using <tool_call>{...}</tool_call> blocks with JSON exactly in OpenAI function-call shape.",
    "If no tool is needed, answer normally.",
]


def render_message_content(content: Any) -> str:
    """Flatten an OpenAI message ``content`` (str | dict | list of blocks) to text."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, dict):
        if "text" in content:
            return str(content.get("text") or "").strip()
        if "content" in content and isinstance(content.get("content"), str):
            return str(content.get("content") or "").strip()
        return json.dumps(content, ensure_ascii=True)
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    parts.append(text.strip())
        return "\n".join(parts).strip()
    return str(content).strip()


def format_messages_as_prompt(
    messages: list[dict[str, Any]],
    *,
    model: str | None = None,
    tools: list[dict[str, Any]] | None = None,
    tool_choice: Any = None,
    header_lines: list[str] | None = None,
    role_renderers: dict[str, Any] | None = None,
) -> str:
    """Render an OpenAI-style message list + tool schemas into one text prompt.

    ``header_lines`` is the backend-specific preamble (falls back to a generic
    one). Tool schemas are embedded as JSON and the model is instructed to emit
    ``<tool_call>{...}</tool_call>`` blocks rather than executing tools itself.

    ``role_renderers`` lets a backend customise how individual roles are
    rendered in the transcript. It's a dict ``{role: callable(content,
    message)}`` whose callable returns the rendered block. Roles not in the
    dict fall back to the default ``"<Label>:\n<content>"`` style. The
    claude-code client uses this to wrap tool results in
    ``<tool_result>…</tool_result>`` so claude doesn't echo bare ``Tool:``
    labels from the transcript back into its own response (#claude-code).
    """
    sections: list[str] = list(header_lines or _DEFAULT_HEADER_LINES)
    if model:
        sections.append(f"JarvisCopilot requested model hint: {model}")

    if isinstance(tools, list) and tools:
        tool_specs: list[dict[str, Any]] = []
        for t in tools:
            if not isinstance(t, dict):
                continue
            fn = t.get("function") or {}
            if not isinstance(fn, dict):
                continue
            name = fn.get("name")
            if not isinstance(name, str) or not name.strip():
                continue
            tool_specs.append(
                {
                    "name": name.strip(),
                    "description": fn.get("description", ""),
                    "parameters": fn.get("parameters", {}),
                }
            )
        if tool_specs:
            sections.append(
                "Available tools (OpenAI function schema). "
                "When using a tool, emit ONLY <tool_call>{...}</tool_call> with one JSON object "
                "containing id/type/function{name,arguments}. arguments must be a JSON string.\n"
                + json.dumps(tool_specs, ensure_ascii=False)
            )

    if tool_choice is not None:
        sections.append(f"Tool choice hint: {json.dumps(tool_choice, ensure_ascii=False)}")

    transcript: list[str] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "unknown").strip().lower()
        if role == "tool":
            role = "tool"
        elif role not in {"system", "user", "assistant"}:
            role = "context"

        content = message.get("content")
        rendered = render_message_content(content)
        if not rendered:
            continue

        # Per-role custom renderer (e.g. claude-code wraps tool results in
        # <tool_result> tags). Falls back to the default labelled-block style.
        if role_renderers and role in role_renderers:
            try:
                block = role_renderers[role](rendered, message)
            except TypeError:
                block = role_renderers[role](rendered)
            transcript.append(block)
        else:
            label = {
                "system": "System",
                "user": "User",
                "assistant": "Assistant",
                "tool": "Tool",
                "context": "Context",
            }.get(role, role.title())
            transcript.append(f"{label}:\n{rendered}")

    if transcript:
        sections.append("Conversation transcript:\n\n" + "\n\n".join(transcript))

    sections.append("Continue the conversation from the latest user request.")
    return "\n\n".join(section.strip() for section in sections if section and section.strip())


def extract_tool_calls_from_text(text: str) -> tuple[list[SimpleNamespace], str]:
    """Parse ``<tool_call>{...}</tool_call>`` blocks out of model text.

    Returns ``(tool_calls, cleaned_text)`` where each tool call is a
    ``SimpleNamespace`` matching the OpenAI tool-call shape the agent loop
    expects, and ``cleaned_text`` is the prose with the tool-call spans removed.
    """
    if not isinstance(text, str) or not text.strip():
        return [], ""

    extracted: list[SimpleNamespace] = []
    consumed_spans: list[tuple[int, int]] = []

    def _try_add_tool_call(raw_json: str) -> None:
        try:
            obj = json.loads(raw_json)
        except Exception:
            return
        if not isinstance(obj, dict):
            return
        fn = obj.get("function")
        if not isinstance(fn, dict):
            return
        fn_name = fn.get("name")
        if not isinstance(fn_name, str) or not fn_name.strip():
            return
        fn_args = fn.get("arguments", "{}")
        if not isinstance(fn_args, str):
            fn_args = json.dumps(fn_args, ensure_ascii=False)
        call_id = obj.get("id")
        if not isinstance(call_id, str) or not call_id.strip():
            call_id = f"cli_call_{len(extracted)+1}"

        extracted.append(
            SimpleNamespace(
                id=call_id,
                call_id=call_id,
                response_item_id=None,
                type="function",
                function=SimpleNamespace(name=fn_name.strip(), arguments=fn_args),
            )
        )

    for m in _TOOL_CALL_BLOCK_RE.finditer(text):
        raw = m.group(1)
        _try_add_tool_call(raw)
        consumed_spans.append((m.start(), m.end()))

    # Only try bare-JSON fallback when no XML blocks were found.
    if not extracted:
        for m in _TOOL_CALL_JSON_RE.finditer(text):
            raw = m.group(0)
            _try_add_tool_call(raw)
            consumed_spans.append((m.start(), m.end()))

    if not consumed_spans:
        return extracted, text.strip()

    consumed_spans.sort()
    merged: list[tuple[int, int]] = []
    for start, end in consumed_spans:
        if not merged or start > merged[-1][1]:
            merged.append((start, end))
        else:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))

    parts: list[str] = []
    cursor = 0
    for start, end in merged:
        if cursor < start:
            parts.append(text[cursor:start])
        cursor = max(cursor, end)
    if cursor < len(text):
        parts.append(text[cursor:])

    cleaned = "\n".join(p.strip() for p in parts if p and p.strip()).strip()
    return extracted, cleaned
