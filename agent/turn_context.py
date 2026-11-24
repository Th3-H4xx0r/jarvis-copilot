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

import hashlib


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


def block_sha(text: str) -> str:
    return hashlib.sha1(str(text).encode("utf-8")).hexdigest()[:16]


def plan_blocks(blocks, prior_user_messages):
    """Which of this turn's blocks to send: ``(send, effective)``.

    A block is carried (not sent) only when the IMMEDIATELY preceding user
    message had exactly this block in effect AND a copy of it that was really
    sent is still in history (not compressed away). So a rule that lapsed for
    a turn (voice → typed → voice) is sent again, and nothing is assumed that
    the model can no longer see. ``effective`` (``[{"kind", "sha", "sent"}]``)
    is what this message keeps in ``api_blocks`` for the next turn."""
    prior = [m for m in (prior_user_messages or []) if isinstance(m, dict)]
    prev_eff = {}
    if prior:
        for e in prior[-1].get("api_blocks") or []:
            if isinstance(e, dict) and e.get("sha"):
                prev_eff[e.get("kind")] = e["sha"]
    sent_in_history = {
        (e.get("kind"), e.get("sha"))
        for m in prior for e in (m.get("api_blocks") or [])
        if isinstance(e, dict) and e.get("sent") and e.get("sha")
    }
    send, effective = [], []
    for block in blocks or []:
        sha = block_sha(block["text"])
        carried = prev_eff.get(block["kind"]) == sha and (block["kind"], sha) in sent_in_history
        effective.append({"kind": block["kind"], "sha": sha, "sent": not carried})
        if not carried:
            send.append(block)
    return send, effective


def reduce_api_content(api_content):
    """List content as text: text parts kept, images become "[screenshot]"
    (base64 data would bloat history, storage and the token estimate)."""
    if not isinstance(api_content, list):
        return api_content
    out = []
    for p in api_content:
        if isinstance(p, dict) and p.get("type") == "text":
            out.append(str(p.get("text", "")))
        elif isinstance(p, dict) and p.get("type") in {"image", "image_url", "input_image"}:
            out.append("[screenshot]")
    return "\n".join(out) if out else None


def finalize_api_copy(msg) -> None:
    """After its turn, a user message's API copy keeps no image data: like the
    content, the image goes from context once the turn is over (one cache
    rewrite at that message, as before this copy existed)."""
    if isinstance(msg, dict) and msg.get("role") == "user" and isinstance(msg.get("api_content"), list):
        msg["api_content"] = reduce_api_content(msg["api_content"])


def finalize_api_copies(messages) -> None:
    for msg in messages or []:
        finalize_api_copy(msg)


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
