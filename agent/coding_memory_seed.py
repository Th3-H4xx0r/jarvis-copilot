"""Builds the ``JARVIS-CONTEXT.md`` seeded into a launched Claude Code session.

The JarvisCopilot builtin memory store keeps entries joined by the ``\\n§\\n``
delimiter (see ``tools/memory_tool.py``). A launched ``claude`` reads plain
markdown, so this reformats the store into markdown bullets and frames it as
background context (not an instruction that overrides the user's request).
"""
from __future__ import annotations

_DELIM = "\n§\n"  # the §-delimited entry separator used by MemoryStore


def _bullets(text: str) -> str:
    if not text or not text.strip():
        return "_(none)_"
    parts = [p.strip() for p in text.split(_DELIM) if p.strip()]
    if not parts:
        return "_(none)_"
    return "\n".join(f"- {p.replace(chr(10), ' ')}" for p in parts)


def build_context_markdown(*, memory_text: str, user_text: str,
                           project_name: str, task: str,
                           long_term: str = "") -> str:
    """Return the markdown body written to ``JARVIS-CONTEXT.md`` at launch."""
    lines = [
        "# JARVIS CONTEXT",
        "",
        "_Injected by JarvisCopilot at session launch. Background only — "
        "follow the user's actual request._",
        "",
        f"**Project:** {project_name}",
    ]
    if task:
        lines.append(f"**Task:** {task}")
    lines += [
        "",
        "## About the user",
        _bullets(user_text),
        "",
        "## Jarvis memory",
        _bullets(memory_text),
    ]
    if long_term and long_term.strip():
        lines += ["", "## Relevant long-term recall", long_term.strip()]
    return "\n".join(lines) + "\n"
