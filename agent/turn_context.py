"""Ephemeral per-turn text appended to the current user message at API-call time.

Keeps the system prompt (and the provider prompt cache) byte-stable while voice
rules, interrupt notes, the speaking device and similar per-turn notes still
reach the model.

Once a user message has been sent with its additions, later calls must send
exactly the same bytes for it, or the provider's prompt cache breaks from that
message on and every later turn pays to write the history again. So the merged
text is kept on the message as an API-only copy (``api_content``, with the
blocks it carried in ``api_blocks``), persisted with the session; the
transcript and UI keep showing only the user's words. A block identical to its
latest copy still in history isn't repeated.
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


def block_kind(text: str) -> str:
    """A block's kind: its first non-empty line, stripped, cut to 80 chars."""
    for line in str(text or "").splitlines():
        line = line.strip()
        if line:
            return line[:80]
    return ""


def turn_blocks(injections, turn_context="") -> list:
    """This turn's additions as ``[{"kind", "text"}]``, in send order: the
    injections, then the turn notes (a str is one block, a list one per item)."""
    parts = [p for p in (injections or []) if p and str(p).strip()]
    if isinstance(turn_context, (list, tuple)):
        parts += [p for p in turn_context if p and str(p).strip()]
    elif turn_context and str(turn_context).strip():
        parts.append(turn_context)
    return [{"kind": block_kind(p), "text": str(p)} for p in parts]


def dedupe_blocks(blocks, prior_user_messages) -> list:
    """Drop a block when the most recent prior user message carrying a block of
    the same kind carried exactly this text — the model already has it. A kind
    no prior message carries (never sent, or compressed away) is sent."""
    out = []
    for block in blocks or []:
        latest = None
        for msg in reversed(prior_user_messages or []):
            for prev in (msg.get("api_blocks") or []) if isinstance(msg, dict) else []:
                if isinstance(prev, dict) and prev.get("kind") == block["kind"]:
                    latest = prev.get("text")
            if latest is not None:
                break
        if latest != block["text"]:
            out.append(block)
    return out


def api_user_content(content, blocks):
    """The user content as sent: the content plus the blocks' text."""
    if not blocks:
        return content
    extra = "\n\n".join(b["text"] for b in blocks)
    if isinstance(content, str):
        return content + "\n\n" + extra
    if isinstance(content, list):
        return list(content) + [{"type": "text", "text": extra}]
    return content
