"""What is actually in the context window right now.

``agent/message_insights.py`` already computes this composition, but only for a
completed API call and only for the webui. From inside a session there was no
way to ask "what is my floor made of" without instrumenting a run by hand --
which is how a 14k floor stays 14k: nobody can see which section owns it.

This renders the same sections for the CURRENT state, so the question is a
command rather than an investigation.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

from agent.message_insights import _CHARS_PER_TOK, _est_tokens, _msg_text

# Rendered in this order when present; anything unrecognised is appended.
_SECTION_ORDER = (
    "system_prompt",
    "context_files",
    "skills",
    "memory",
    "rules",
    "mcp",
    "subagents",
    "tool_schemas",
    "conversation_history",
    "user_message",
)


def _context_limit(agent: Any) -> Optional[int]:
    """The model's context window, if we know it."""
    model = (getattr(agent, "model", "") or "").strip()
    if not model:
        return None
    try:
        from agent.model_metadata import DEFAULT_CONTEXT_LENGTHS_LOWER

        return DEFAULT_CONTEXT_LENGTHS_LOWER.get(model.lower())
    except Exception:
        return None


def compute(agent: Any, api_messages: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    """Token estimate per section of the live context window.

    Estimates, not a tokenizer count: the question is proportion -- which
    section owns the floor -- and an estimate answers that without a round trip.
    """
    sections: Dict[str, int] = {}

    prompt_sections = getattr(agent, "_prompt_sections", {}) or {}
    if prompt_sections:
        for label, chars in prompt_sections.items():
            try:
                sections[str(label)] = max(0, int(chars) // _CHARS_PER_TOK)
            except (TypeError, ValueError):
                continue
    else:
        cached = getattr(agent, "_cached_system_prompt", None)
        if cached:
            sections["system_prompt"] = _est_tokens(cached)

    tools = getattr(agent, "tools", None)
    if tools:
        sections["tool_schemas"] = _est_tokens(tools)

    msgs = api_messages
    if msgs is None:
        msgs = getattr(agent, "messages", None) or []
    convo = [m for m in msgs if isinstance(m, dict) and m.get("role") != "system"]
    if convo:
        sections["conversation_history"] = sum(_est_tokens(_msg_text(m)) for m in convo)

    total = sum(sections.values())
    limit = _context_limit(agent)
    return {
        "sections": sections,
        "total": total,
        "limit": limit,
        "pct": (total / limit * 100.0) if limit else None,
        "model": getattr(agent, "model", "") or "",
    }


def _ordered(sections: Dict[str, int]) -> List[Tuple[str, int]]:
    known = [(k, sections[k]) for k in _SECTION_ORDER if k in sections]
    rest = sorted(
        ((k, v) for k, v in sections.items() if k not in _SECTION_ORDER),
        key=lambda kv: -kv[1],
    )
    return known + rest


def render(breakdown: Dict[str, Any], width: int = 28) -> str:
    """A plain-text bar chart of the breakdown, biggest section flagged."""
    sections = breakdown.get("sections") or {}
    if not sections:
        return "No context composition available yet — send a message first."

    total = breakdown.get("total") or 0
    rows = _ordered(sections)
    biggest = max(rows, key=lambda kv: kv[1])[0] if rows else None
    label_w = max(len(k) for k, _ in rows)

    lines = []
    for name, tokens in rows:
        share = (tokens / total) if total else 0
        filled = int(round(share * width))
        bar = "█" * filled + "·" * (width - filled)
        mark = "  <- biggest" if name == biggest and len(rows) > 1 else ""
        lines.append(f"  {name.replace('_', ' '):<{label_w}}  {bar} {tokens:>7,}  "
                     f"{share * 100:>5.1f}%{mark}")

    limit, pct = breakdown.get("limit"), breakdown.get("pct")
    header = f"Context: {total:,} tokens"
    if limit:
        header += f" of {limit:,} ({pct:.1f}% full)"
    if breakdown.get("model"):
        header += f"  [{breakdown['model']}]"

    footer = ("\n  Estimated from character counts, so treat these as "
              "proportions rather than exact counts.")
    return header + "\n" + "\n".join(lines) + footer
