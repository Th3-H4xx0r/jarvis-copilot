"""Per-message token usage + input composition for the insights "Messages" screen.

The model API returns only TOTAL input/output tokens. To show *what the input was
made of*, we estimate a per-section split (chars/4) from:
  - the cached system-prompt sections recorded during build_system_prompt_parts
    (agent._prompt_sections — identity, behavioral_guidance, lazy_manifest,
    skills_catalog, memory, ...),
  - the advertised tool schemas (agent.tools),
  - the conversation history, and
  - the current user message.
The estimate won't sum exactly to the API's input total (estimation + API
overhead); the record stores BOTH the exact API totals and the estimated split.
Best-effort throughout — insights must never break a turn.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

_CHARS_PER_TOK = 4


def _est_tokens(text: Any) -> int:
    s = text if isinstance(text, str) else json.dumps(text, default=str)
    try:
        from agent.model_metadata import estimate_tokens_rough
        return int(estimate_tokens_rough(s))
    except Exception:
        return (len(s) + 3) // _CHARS_PER_TOK


def _msg_text(m: Dict[str, Any]) -> str:
    c = m.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = [p.get("text", "") for p in c if isinstance(p, dict)]
        # tool_calls / non-text parts still cost tokens; approximate via json
        return " ".join(parts) if parts else json.dumps(c, default=str)
    if c is None and m.get("tool_calls"):
        return json.dumps(m.get("tool_calls"), default=str)
    return json.dumps(c, default=str) if c is not None else ""


def compute_message_composition(agent: Any, api_messages: Optional[List[Dict[str, Any]]],
                                canonical_usage: Any, latency_s: Optional[float] = None
                                ) -> Dict[str, Any]:
    """Return a per-API-call usage + estimated input-composition dict."""
    sections: Dict[str, int] = {}

    # System-prompt sub-sections (chars recorded at build time → tokens).
    for label, chars in (getattr(agent, "_prompt_sections", {}) or {}).items():
        try:
            sections[str(label)] = max(0, int(chars) // _CHARS_PER_TOK)
        except Exception:
            continue

    # Advertised tool schemas this call.
    tools = getattr(agent, "tools", None)
    if tools:
        sections["tool_schemas"] = _est_tokens(tools)

    # Conversation history vs the current user message (system msg already
    # accounted for above via the prompt sections).
    msgs = [m for m in (api_messages or [])
            if isinstance(m, dict) and m.get("role") != "system"]
    if msgs:
        sections["user_message"] = _est_tokens(_msg_text(msgs[-1]))
        history = msgs[:-1]
        if history:
            sections["conversation_history"] = sum(_est_tokens(_msg_text(m)) for m in history)

    def _u(attr: str) -> int:
        try:
            return int(getattr(canonical_usage, attr, 0) or 0)
        except Exception:
            return 0

    return {
        "in_total": _u("input_tokens"),
        "out_total": _u("output_tokens"),
        "cache_read": _u("cache_read_tokens"),
        "cache_write": _u("cache_write_tokens"),
        "reasoning": _u("reasoning_tokens"),
        "latency_s": latency_s,
        "estimated_in": sum(sections.values()),
        "sections": sections,
        "estimated": True,
    }
