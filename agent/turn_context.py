"""Ephemeral per-turn text appended to the current user message at API-call time.

Keeps the system prompt (and the provider prompt cache) byte-stable while voice
rules, interrupt notes, the speaking device and similar per-turn notes still
reach the model. Never persisted: the stored user message is untouched.
"""
from __future__ import annotations


def merge_injections(content, injections, turn_context: str = ""):
    parts = [p for p in (injections or []) if p]
    if turn_context:
        parts.append(turn_context)
    if not parts:
        return content
    extra = "\n\n".join(parts)
    if isinstance(content, str):
        return content + "\n\n" + extra
    if isinstance(content, list):
        return list(content) + [{"type": "text", "text": extra}]
    return content
