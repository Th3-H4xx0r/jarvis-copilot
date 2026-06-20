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

import base64
import json
import logging
import re
from types import SimpleNamespace
from typing import Any

logger = logging.getLogger(__name__)

_TOOL_CALL_BLOCK_RE = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.DOTALL)
_TOOL_CALL_JSON_RE = re.compile(
    r"\{\s*\"id\"\s*:\s*\"[^\"]+\"\s*,\s*\"type\"\s*:\s*\"function\"\s*,\s*\"function\"\s*:\s*\{.*?\}\s*\}",
    re.DOTALL,
)

# ── Output sanitisation ──────────────────────────────────────────────────────
#
# An external CLI used as a pure text generator is fed past tool results in the
# transcript wrapped in HTML-comment markers (``<!-- jc:tool_result … -->`` …
# ``<!-- /jc:tool_result -->``). The header instructs the model NOT to reproduce
# them, but weaker/faster generations sometimes echo the whole block — including
# the raw JSON tool output — straight into the visible reply (often mangling the
# tag, e.g. ``jc:toolresult``). JarvisCopilot already renders tool results as
# separate UI elements, so any such echo is pure noise. These deterministic
# strippers are the real fix: they run on the model's OUTPUT and never depend on
# the model obeying instructions. ``tool_?result`` matches both the correct and
# the mangled (underscore-dropped) spellings.

# The model echoes tool-result markers in several mangled shapes:
#   (1) paired single-line comments:  <!-- jc:tool_result name=x --> … <!-- /jc:tool_result -->
#   (2) one multi-line comment:        <!--\njc:tool_result name=x\n<body>\n-->
#   (3) the mangled spelling jc:toolresult (underscore dropped) in either form.
# Strip the PAIRED block (markers + the content between them) FIRST so we don't
# eat interleaved reply prose, then any remaining single jc:tool_result comment.
_PAIRED_RESULT_BLOCK_RE = re.compile(
    r"<!--(?:(?!-->)[\s\S])*?jc:tool_?result(?:(?!-->)[\s\S])*?-->"   # opening marker comment
    r"[\s\S]*?"                                                        # tool-result body
    r"<!--(?:(?!-->)[\s\S])*?/\s*jc:tool_?result(?:(?!-->)[\s\S])*?-->",  # closing marker comment
    re.IGNORECASE,
)
_RESULT_COMMENT_RE = re.compile(
    r"<!--(?:(?!-->)[\s\S])*?jc:tool_?result(?:(?!-->)[\s\S])*?-->",
    re.IGNORECASE,
)
# Echoed XML-style tool-result element (an older mimicry shape).
_ECHOED_TOOLRESULT_XML_RE = re.compile(
    r"<\s*tool_?result\b.*?<\s*/\s*tool_?result\s*>",
    re.DOTALL | re.IGNORECASE,
)
_EXCESS_BLANKS_RE = re.compile(r"\n{3,}")

# A leaked transcript reproduces the format JarvisCopilot feeds the model. Some
# signals are UNAMBIGUOUS leaks — jc markers, comment fragments, <tool_result>
# XML, echoed tool-CALL JSON, and a bare/marker-introducing role label — and are
# always dropped (`_is_leak_line`). Others are AMBIGUOUS — tool-output JSON like
# `{"exit_code":0}` that a user might legitimately ask the model to print — and
# are dropped ONLY when adjacent to an unambiguous leak line (i.e. part of a
# transcript dump). Isolated user-requested JSON and ordinary prose survive.
_HARD_LABEL_RE = re.compile(
    r"^\s*(?:User|Assistant|Tool|System|Context|Human|AI)\s*:\s*(?:<!--|$)",
    re.IGNORECASE,
)
_XML_TOOL_RESULT_LINE_RE = re.compile(r"^\s*</?\s*tool_?result\b", re.IGNORECASE)
_GENERIC_COMMENT_SPAN_RE = re.compile(r"<!--[\s\S]*?-->")
# Defense-in-depth: an `[already executed — do NOT call again: …]` history note
# (if the model ever echoes one) is internal scaffolding, never reply prose.
_ALREADY_EXECUTED_SPAN_RE = re.compile(r"\[already executed\b[^\]\n]*\]", re.IGNORECASE)
# An echoed "(result of `X` — you already called it; do NOT call `X` again)" note
# (from an older transcript format, or a paraphrase) is internal scaffolding.
_RESULT_OF_NOTE_RE = re.compile(
    r"\(\s*result of\b[^)\n]*?already called it[^)\n]*\)", re.IGNORECASE)
# Ambiguous tool-OUTPUT JSON signatures (contextual drop only).
_TOOL_RESULT_JSON_SIGNATURES = (
    '"exit_code"', '"stdout"', '"stderr"', '"output"', '"loaded"', '"schemas"',
)


def _is_echoed_tool_call_line(stripped: str) -> bool:
    """An echoed past tool call — an Anthropic ``toolu_`` id or the function-call
    shape. Effectively never produced as genuine reply prose."""
    if not stripped.startswith(("{", "[")):
        return False
    if '"toolu_' in stripped:
        return True
    has_fn = '"type": "function"' in stripped or '"type":"function"' in stripped
    return has_fn and '"id"' in stripped


def _is_tool_result_json_line(stripped: str) -> bool:
    return stripped.startswith(("{", "[")) and any(
        sig in stripped for sig in _TOOL_RESULT_JSON_SIGNATURES
    )


def _is_leak_line(line: str) -> bool:
    """True when a line is UNAMBIGUOUS leaked transcript scaffolding.

    High precision: only signals that effectively never occur in genuine reply
    prose. Ambiguous tool-output JSON is handled contextually by
    ``sanitize_model_text`` and is intentionally NOT flagged here.
    """
    stripped = line.strip()
    if not stripped:
        return False
    if "<!--" in stripped or stripped.startswith("-->") or stripped == "-->":
        return True
    low = stripped.lower()
    if low.startswith("[already executed"):
        return True
    if "jc:tool_result" in low or "jc:toolresult" in low:
        return True
    if _XML_TOOL_RESULT_LINE_RE.match(line):
        return True
    if _HARD_LABEL_RE.match(line):
        return True
    if _is_echoed_tool_call_line(stripped):
        return True
    return False


def looks_like_leak_start(partial_line: str) -> bool:
    """Heuristic for an in-progress line that may resolve into leaked scaffolding.

    Conservative: only flags lines that begin like a label, a JSON/array object,
    or a tag — normal prose is never flagged.
    """
    t = partial_line.lstrip()
    if not t:
        return False
    if t[0] in "{[<":
        return True
    if re.match(r"^(?:User|Assistant|Tool|System|Context|Human|AI)\b\s*:?", t, re.IGNORECASE):
        return True
    return False


def sanitize_model_text(text: str) -> str:
    """Strip leaked internal transcript scaffolding from model output.

    Deterministic safety net for the text-shim providers (claude-code,
    copilot-acp). Removes jc tool-result marker blocks/comments (incl. the
    mangled ``jc:toolresult`` spelling and multi-line form), echoed
    ``<tool_result>`` XML, and any leftover HTML-comment SPAN (keeping the prose
    around it). Then drops leaked transcript lines: unambiguous ones always, and
    ambiguous tool-output JSON only when adjacent to an unambiguous leak line (a
    transcript dump). A user's own isolated JSON and ordinary prose are
    preserved. Returns text unchanged when there's nothing to strip.
    """
    if not isinstance(text, str) or not text:
        return text or ""
    # 1. Paired jc tool-result blocks (marker + arbitrary body + marker), then
    #    echoed <tool_result>…</tool_result> XML.
    cleaned = _PAIRED_RESULT_BLOCK_RE.sub("", text)
    cleaned = _ECHOED_TOOLRESULT_XML_RE.sub("", cleaned)
    cleaned = _ALREADY_EXECUTED_SPAN_RE.sub("", cleaned)
    cleaned = _RESULT_OF_NOTE_RE.sub("", cleaned)

    # 2. Single line pass. jc-marker lines are HARD-dropped IN PLACE (they stay
    #    as anchors so adjacent ambiguous tool-output JSON drops with them);
    #    multi-line HTML comments are dropped through their close.
    lines = cleaned.split("\n")
    n = len(lines)
    drop = [False] * n
    soft = [False] * n
    inside_comment = False
    for i, line in enumerate(lines):
        s = line.strip()
        if inside_comment:
            drop[i] = True
            if "-->" in line:
                inside_comment = False
            continue
        low = s.lower()
        hard = (
            "jc:tool_result" in low
            or "jc:toolresult" in low
            or bool(_XML_TOOL_RESULT_LINE_RE.match(line))
            or bool(_HARD_LABEL_RE.match(line))
            or _is_echoed_tool_call_line(s)
            or s.startswith("-->")
        )
        # Opening of a multi-line HTML comment → drop through its close.
        if "<!--" in line and "-->" not in line.split("<!--", 1)[1]:
            inside_comment = True
            hard = True
        drop[i] = hard
        if not hard and _is_tool_result_json_line(s):
            soft[i] = True

    def _prev_nonblank(i: int) -> int:
        j = i - 1
        while j >= 0 and not lines[j].strip():
            j -= 1
        return j

    def _next_nonblank(i: int) -> int:
        j = i + 1
        while j < n and not lines[j].strip():
            j += 1
        return j

    # 3. Drop an ambiguous tool-output JSON line when a non-blank neighbour is
    #    already dropped; propagate so a whole contiguous dump goes.
    changed = True
    while changed:
        changed = False
        for i in range(n):
            if soft[i] and not drop[i]:
                p, q = _prev_nonblank(i), _next_nonblank(i)
                if (p >= 0 and drop[p]) or (q < n and drop[q]):
                    drop[i] = True
                    changed = True

    cleaned = "\n".join(lines[i] for i in range(n) if not drop[i])
    # 4. Strip any residual COMPLETE generic comment span on surviving lines
    #    (keeps the prose around an inline `<!-- … -->`).
    cleaned = _GENERIC_COMMENT_SPAN_RE.sub("", cleaned)
    cleaned = _EXCESS_BLANKS_RE.sub("\n\n", cleaned)
    return cleaned.strip()

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


def _summarize_tool_calls(tool_calls: Any) -> str:
    """Render an assistant message's tool_calls as ``name(args), name(args)``.

    Accepts both dict-shaped (``{"function": {"name", "arguments"}}``) and
    object-shaped (``tc.function.name``) tool calls. Arguments are truncated so
    a large payload (e.g. a diff) doesn't bloat the prompt. Returns "" when there
    are no usable calls.
    """
    if not tool_calls:
        return ""
    parts: list[str] = []
    for tc in tool_calls:
        fn = tc.get("function") if isinstance(tc, dict) else getattr(tc, "function", None)
        if isinstance(fn, dict):
            name = str(fn.get("name") or "").strip()
            args = fn.get("arguments")
        elif fn is not None:
            name = str(getattr(fn, "name", "") or "").strip()
            args = getattr(fn, "arguments", None)
        else:
            name, args = "", None
        if not name:
            continue
        if args is None:
            args = ""
        if not isinstance(args, str):
            try:
                args = json.dumps(args, ensure_ascii=False)
            except Exception:
                args = str(args)
        args = args.strip()
        if len(args) > 200:
            args = args[:200] + "…"
        parts.append(f"{name}({args})" if args else f"{name}()")
    return ", ".join(parts)


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
    last_role = ""
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
            # A pure tool-call assistant turn (empty content) carries no prose.
            # The "you already ran this" signal that prevents the agent loop is
            # attached to the tool RESULT below instead — rendering the call as a
            # text line taught the model a competing, non-executable format it
            # then mimicked (#claude-code loop/skip).
            continue

        # NOTE: we deliberately do NOT annotate tool results with a "you already
        # called X" note here — the model echoed that note verbatim into its
        # reply (confusing output). Loop/repeat prevention is now enforced
        # DETERMINISTICALLY by filter_repeat_tool_calls() (drops a turn whose
        # calls are all exact repeats), not by hoping the model reads a note.

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
        last_role = role

    if transcript:
        sections.append("Conversation transcript:\n\n" + "\n\n".join(transcript))

    if last_role == "tool":
        # After tool results, steer the model to USE them rather than re-address
        # the user's request from scratch (which re-greets and re-calls → loop).
        sections.append(
            "The tool results above are from calls you ALREADY made. Do NOT "
            "repeat any tool call that already has a result above. Use the "
            "results to continue toward the user's goal, or give your final "
            "answer with no tool call."
        )
    else:
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


def _canon_tool_args(args: Any) -> str:
    """Canonicalise tool-call arguments so formatting differences don't defeat a
    repeat comparison (JSON re-serialised with sorted keys when possible)."""
    if args is None:
        return ""
    if not isinstance(args, str):
        try:
            return json.dumps(args, sort_keys=True, ensure_ascii=False)
        except Exception:
            return str(args)
    s = args.strip()
    try:
        return json.dumps(json.loads(s), sort_keys=True, ensure_ascii=False)
    except Exception:
        return s


def _tool_call_key(tc: Any) -> tuple[str, str]:
    fn = tc.get("function") if isinstance(tc, dict) else getattr(tc, "function", None)
    if isinstance(fn, dict):
        name, args = fn.get("name"), fn.get("arguments")
    elif fn is not None:
        name, args = getattr(fn, "name", None), getattr(fn, "arguments", None)
    else:
        name, args = None, None
    return (str(name or "").strip(), _canon_tool_args(args))


def filter_repeat_tool_calls(
    tool_calls: list[SimpleNamespace], messages: list[dict[str, Any]] | None
) -> list[SimpleNamespace]:
    """Deterministic loop-breaker for the text-shim providers.

    The model sometimes re-emits the SAME tool call(s) it already made in a prior
    turn (an infinite/near-infinite agent loop). If EVERY freshly-parsed call is
    an exact (name + canonical-args) repeat of one already in the history, the
    turn is a pure repeat → return [] so the loop ends with a final answer
    instead of re-running. If even one call is new, keep them all (real progress
    is being made — never interfere). Independent of the model reading any note.
    """
    if not tool_calls:
        return tool_calls
    seen: set[tuple[str, str]] = set()
    for m in messages or []:
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        for tc in m.get("tool_calls") or []:
            seen.add(_tool_call_key(tc))
    if not seen:
        return tool_calls
    fresh = [tc for tc in tool_calls if _tool_call_key(tc) not in seen]
    return tool_calls if fresh else []


# ── Vision / image input ─────────────────────────────────────────────────────
#
# The text-prompt path (``format_messages_as_prompt`` → stdin) drops images.
# To support vision the claude-code client switches to the CLI's stream-json
# INPUT format and sends one user turn carrying the flattened text prompt plus
# the conversation's images as base64 ``image`` content blocks. These helpers
# extract images from OpenAI-shaped messages and build that JSON turn. They are
# only engaged when at least one image is present, so text-only requests keep
# the proven plain-stdin path untouched.

_IMAGE_FETCH_TIMEOUT_SECONDS = 12.0


def _parse_data_url(url: str) -> tuple[str, str] | None:
    """Parse a ``data:<media>;base64,<data>`` URL → (media_type, b64_data)."""
    if not isinstance(url, str) or not url.startswith("data:"):
        return None
    try:
        header, b64data = url.split(",", 1)
    except ValueError:
        return None
    meta = header[len("data:"):]
    if "base64" not in meta.lower():
        return None
    media_type = (meta.split(";", 1)[0] or "").strip() or "image/png"
    data = b64data.strip()
    return (media_type, data) if data else None


def _image_block_from_url(url: str) -> dict[str, Any] | None:
    """Build a claude ``image`` content block from a data: or http(s) URL.

    data: URLs are decoded inline. http(s) URLs are fetched + base64-encoded
    (the CLI runs with native tools disabled, so it can't fetch them itself).
    Any failure returns None — the caller drops that image rather than erroring.
    """
    parsed = _parse_data_url(url)
    if parsed:
        media_type, data = parsed
        return {"type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": data}}
    if isinstance(url, str) and url.startswith(("http://", "https://")):
        try:
            import urllib.request

            req = urllib.request.Request(url, headers={"User-Agent": "JarvisCopilot"})
            with urllib.request.urlopen(req, timeout=_IMAGE_FETCH_TIMEOUT_SECONDS) as resp:
                raw = resp.read()
                ctype = (resp.headers.get("Content-Type") or "image/png").split(";")[0].strip()
            media_type = ctype or "image/png"
            return {"type": "image",
                    "source": {"type": "base64", "media_type": media_type,
                               "data": base64.b64encode(raw).decode("ascii")}}
        except Exception:
            logger.debug("claude-code: could not fetch image url for vision", exc_info=True)
            return None
    return None


def extract_image_blocks(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collect claude ``image`` content blocks from OpenAI-shaped messages.

    Handles OpenAI ``{"type":"image_url","image_url":{"url":…}}`` (and the bare
    string form) plus already-claude-shaped ``{"type":"image","source":{…}}``.
    """
    blocks: list[dict[str, Any]] = []
    for message in messages or []:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            itype = item.get("type")
            if itype == "image_url":
                iu = item.get("image_url")
                if isinstance(iu, dict):
                    url = iu.get("url") or ""
                elif isinstance(iu, str):
                    url = iu
                else:
                    url = ""
                block = _image_block_from_url(url) if url else None
                if block:
                    blocks.append(block)
            elif itype == "image" and isinstance(item.get("source"), dict):
                blocks.append({"type": "image", "source": item["source"]})
    return blocks


def build_stream_json_user_input(prompt_text: str, image_blocks: list[dict[str, Any]]) -> str:
    """Build one claude stream-json INPUT line: a user turn with text + images."""
    content: list[dict[str, Any]] = [{"type": "text", "text": prompt_text or ""}]
    content.extend(image_blocks or [])
    return json.dumps(
        {"type": "user", "message": {"role": "user", "content": content}},
        ensure_ascii=False,
    )
