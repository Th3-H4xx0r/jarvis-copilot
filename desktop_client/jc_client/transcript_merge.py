"""Merge two copies of one agent transcript without losing a line.

Pure stdlib. jc-client imports it as a package module and the server loads the
same file by path (``agent/transcript_merge_shim.py``), so the Mac and the
server can never disagree on what a merge means.

Transcripts are append-only JSONL. ``base`` is the copy being updated and
``incoming`` the other machine's copy:

* Claude lines carry a ``uuid``; lines are matched by it (lines without one,
  like summaries, are matched by their exact text).
* Codex rollout lines carry no per-line id, so they are matched by position:
  one copy must be a prefix of the other.

When both copies grew past their last shared line, the conversation forked:
``merged`` follows ``incoming`` and ``base``'s extra lines come back as
``fork_tail`` for the caller to keep as a separate copy. Every input line ends
up in ``merged`` or ``fork_tail``.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field


@dataclass
class MergeResult:
    merged: list = field(default_factory=list)
    fork_tail: list = field(default_factory=list)
    kind: str = "equal"   # equal | appended | forked


def line_id(line: str, agent: str):
    """The line's identity for ``agent``: Claude's ``uuid``, else None."""
    if agent == "codex":
        return None
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return None
    uid = obj.get("uuid") if isinstance(obj, dict) else None
    return uid if isinstance(uid, str) and uid else None


def _ident(line: str, agent: str) -> str:
    uid = line_id(line, agent)
    return "u:" + uid if uid else "t:" + line


def merge(base: list, incoming: list, agent: str) -> MergeResult:
    if agent == "codex":
        return _merge_positional(list(base), list(incoming))
    return _merge_by_id(list(base), list(incoming), agent)


def _merge_positional(base: list, incoming: list) -> MergeResult:
    if incoming[:len(base)] == base:
        return MergeResult(incoming, [], "appended" if len(incoming) > len(base) else "equal")
    if base[:len(incoming)] == incoming:
        return MergeResult(base, [], "equal")
    p = 0
    while p < min(len(base), len(incoming)) and base[p] == incoming[p]:
        p += 1
    return MergeResult(incoming, base[p:], "forked")


def _merge_by_id(base: list, incoming: list, agent: str) -> MergeResult:
    base_ids = [_ident(x, agent) for x in base]
    in_ids = [_ident(x, agent) for x in incoming]
    in_set, base_set = set(in_ids), set(base_ids)
    shared = in_set & base_set
    last_base = max((i for i, k in enumerate(base_ids) if k in shared), default=-1)
    base_extra = [base[i] for i in range(last_base + 1, len(base)) if base_ids[i] not in in_set]
    in_extra = [incoming[i] for i, k in enumerate(in_ids) if k not in base_set]
    if not in_extra:
        return MergeResult(base, [], "equal")
    if not base_extra:
        return MergeResult(base + in_extra, [], "appended")
    keep = base[:last_base + 1]
    kept = set(base_ids[:last_base + 1])
    tail = [incoming[i] for i, k in enumerate(in_ids) if k not in kept]
    return MergeResult(keep + tail, base_extra, "forked")
