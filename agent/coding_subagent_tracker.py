"""Track Claude Code subagent spawns from a session JSONL transcript.

A Claude Code session writes a JSONL transcript (one JSON object per line).
When the agent spawns a subagent it emits a ``Task`` tool_use content block::

    {"type": "tool_use", "id": "toolu_123", "name": "Task",
     "input": {"subagent_type": "explorer", "description": "find X", "prompt": "..."}}

When that subagent finishes, a later message carries a matching ``tool_result``::

    {"type": "tool_result", "tool_use_id": "toolu_123", ...}

Messages come in two wrapping shapes which this module normalizes:

  * wrapped:  ``{"type": "assistant", "message": {"role": ..., "content": [...]}}``
  * bare:     ``{"role": "assistant", "content": [...]}``

Parsing is deliberately tolerant: malformed JSON lines, unexpected shapes, and
missing fields are skipped/defaulted rather than raised. A missing transcript
file yields an empty result.

Public API:
    parse_subagents(jsonl_path: str) -> list[dict]
    summarize(subagents: list[dict]) -> dict
    iter_tool_uses(obj: dict) -> list[dict]
    iter_tool_results(obj: dict) -> list[str]
"""

from __future__ import annotations

import json
from pathlib import Path

__all__ = [
    "parse_subagents",
    "summarize",
    "iter_tool_uses",
    "iter_tool_results",
]


def _content_blocks(obj):
    """Return the list of content blocks from either message-wrapping shape.

    Handles wrapped (``obj["message"]["content"]``) and bare (``obj["content"]``)
    shapes. Anything that is not a list of blocks yields an empty list.
    """
    if not isinstance(obj, dict):
        return []

    message = obj.get("message")
    if isinstance(message, dict) and isinstance(message.get("content"), list):
        return message["content"]

    content = obj.get("content")
    if isinstance(content, list):
        return content

    return []


def iter_tool_uses(obj):
    """Return the ``tool_use`` content blocks in ``obj`` (both shapes).

    Each returned item is the raw block dict (with ``id``, ``name``, ``input``).
    Non-dict blocks and blocks without ``type == "tool_use"`` are skipped.
    """
    uses = []
    for block in _content_blocks(obj):
        if isinstance(block, dict) and block.get("type") == "tool_use":
            uses.append(block)
    return uses


def iter_tool_results(obj):
    """Return the ``tool_use_id`` strings of ``tool_result`` blocks in ``obj``."""
    ids = []
    for block in _content_blocks(obj):
        if isinstance(block, dict) and block.get("type") == "tool_result":
            tool_use_id = block.get("tool_use_id")
            if isinstance(tool_use_id, str):
                ids.append(tool_use_id)
    return ids


def _iter_objects(jsonl_path):
    """Yield parsed JSON objects from a JSONL file, skipping bad/blank lines.

    A missing file yields nothing. Lines that fail to parse are skipped.
    """
    path = Path(jsonl_path)
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, NotADirectoryError, IsADirectoryError, OSError):
        return

    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except (ValueError, TypeError):
            continue


def parse_subagents(jsonl_path):
    """Parse a transcript and return one dict per spawned Task subagent.

    Returns a list of::

        {"id": <tool_use id>, "sub_type": <input.subagent_type or "">,
         "description": <input.description or "">,
         "status": "completed" if a matching tool_result exists else "running"}

    Discovery order is preserved. Subagents whose ``tool_use_id`` appears in a
    later (or earlier) ``tool_result`` are marked ``completed``. Tolerates
    malformed lines, missing fields, and a missing file (returns ``[]``).
    """
    subagents = []
    completed_ids = set()
    seen_ids = set()

    for obj in _iter_objects(jsonl_path):
        # Collect Task spawns in discovery order.
        for use in iter_tool_uses(obj):
            if use.get("name") != "Task":
                continue
            tool_id = use.get("id")
            if not isinstance(tool_id, str):
                continue
            if tool_id in seen_ids:
                continue
            seen_ids.add(tool_id)

            raw_input = use.get("input")
            if not isinstance(raw_input, dict):
                raw_input = {}

            sub_type = raw_input.get("subagent_type")
            description = raw_input.get("description")

            subagents.append(
                {
                    "id": tool_id,
                    "sub_type": sub_type if isinstance(sub_type, str) else "",
                    "description": description
                    if isinstance(description, str)
                    else "",
                    # Filled in after the full scan.
                    "status": "running",
                }
            )

        # Collect completion markers (may appear before or after the spawn).
        for tool_use_id in iter_tool_results(obj):
            completed_ids.add(tool_use_id)

    for sub in subagents:
        if sub["id"] in completed_ids:
            sub["status"] = "completed"

    return subagents


def summarize(subagents):
    """Roll up subagents into ``{"total": n, "running": r, "completed": c}``."""
    total = len(subagents)
    completed = sum(1 for s in subagents if s.get("status") == "completed")
    running = total - completed
    return {"total": total, "running": running, "completed": completed}
