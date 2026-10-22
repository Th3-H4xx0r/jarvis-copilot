"""Recall: the multi-channel pipeline every turn uses, plus the old hybrid.

``recall`` runs four channels at once — meaning (vectors), keywords (bm25 over
body + map slots), entities (people/places/events named in the question or the
recent turns) and time (what happens in the window "this weekend" names) —
fuses them by rank (RRF), weighs the result by salience (an event in the next
two weeks, importance, recency, pinned; minus superseded), drops weak hits and
follows one link from the best ones. ``hybrid_recall`` is the previous
two-channel fusion, kept for the eval baseline (``recall_legacy``).

Scoring note (bug-sweep M2): the vector arm uses ``max(cos, 0)`` so that "no
semantic signal" maps to 0 (not 0.5), keeping both arms on a comparable [0,1]
scale where 0 means "no match" — otherwise the fusion weights are meaningless.
"""
from __future__ import annotations

import logging
import math
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional

from .embed import Embedder
from .store import Chunk, GLOBAL_NS, MemoryStore
from .timeparse import TimeWindow, window as time_window

logger = logging.getLogger(__name__)

VECTOR_WEIGHT = 0.65
KEYWORD_WEIGHT = 0.35


@dataclass
class Hit:
    chunk: Chunk
    score: float


def parse_when(value, *, end_of_day: bool, zone) -> Optional[float]:
    """Epoch seconds for an ISO date or datetime ('2026-10-19', '2026-10-19T18:00',
    with or without an offset). A bare date is the start of that day in ``zone``,
    or its last instant when ``end_of_day`` — so until='2026-10-19' covers the
    whole of the 19th where he lives. None when empty or unreadable."""
    text = str(value or "").strip()
    if not text:
        return None
    try:
        if len(text) == 10:
            day = datetime.fromisoformat(text).replace(tzinfo=zone)
            return (day + timedelta(days=1)).timestamp() - 0.001 if end_of_day else day.timestamp()
        when = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if when.tzinfo is None:
            when = when.replace(tzinfo=zone)
        return when.timestamp()
    except ValueError:
        return None


def hybrid_recall(store: MemoryStore, embedder: Embedder, query: str,
                  namespace: str = GLOBAL_NS, limit: int = 5,
                  min_relevance: float = 0.0, candidate_ids=None) -> List[Hit]:
    """``candidate_ids`` (a set) limits the ranking to those memories — the
    filtered lookup's way of searching inside one person's chats or one day."""
    if not query or not query.strip():
        return []
    vec_hits = {}
    try:
        qv = embedder.embed_one(query)
        for cid, cos in store.vector_search(namespace, qv, embedder.signature, limit * 4,
                                            only_ids=candidate_ids):
            vec_hits[cid] = max(cos, 0.0)  # no signal -> 0, not 0.5
    except Exception as e:
        logger.warning("jarvis_memory vector arm failed: %s", e)
    kw_hits = dict(store.keyword_search(namespace, query, limit * 4, only_ids=candidate_ids))
    have_vec = bool(vec_hits)
    scored = []
    for cid in set(vec_hits) | set(kw_hits):
        v = vec_hits.get(cid, 0.0)
        k = kw_hits.get(cid, 0.0)
        score = (v * VECTOR_WEIGHT + k * KEYWORD_WEIGHT) if have_vec else k
        scored.append((cid, score))
    scored.sort(key=lambda x: x[1], reverse=True)
    scored = [(c, s) for c, s in scored if s >= min_relevance][:limit]
    chunks = {c.id: c for c in store.get_chunks([c for c, _ in scored])}
    return [Hit(chunk=chunks[c], score=s) for c, s in scored if c in chunks]


def _when_tag(chunk: Chunk, zone) -> str:
    when = chunk.event_start or chunk.created_at
    try:
        d = datetime.fromtimestamp(float(when), zone)
    except Exception:
        return ""
    kind = (chunk.source or "").split(":", 1)[0]
    kind = {"fact": "chat", "builtin": "noted", "tool": "noted"}.get(kind, kind)
    return f" [{d:%a} {d.day} {d:%b}" + (f" {d.year}" if d.year != datetime.now(zone).year else "") \
        + (f" · {kind}" if kind else "") + ("" if not chunk.valid_to else " · no longer true") + "]"


def format_recall_block(hits: List[Hit], max_context_chars: int = 2000, zone=None) -> str:
    """Render hits as a memory block, budgeted by char count.

    Always includes the header + at least the top hit when any hits exist;
    additional hits are added until the budget would be exceeded. With a
    ``zone`` each line carries when it happens (or was said) and where from.
    """
    if not hits:
        return ""
    header = "[Long-term memory]"
    lines = [header]
    used = len(header)
    for i, h in enumerate(hits):
        body = " ".join(h.chunk.body.split())
        line = f"- {body}" + (_when_tag(h.chunk, zone) if zone is not None else "")
        if i > 0 and used + len(line) + 1 > max_context_chars:
            break
        lines.append(line)
        used += len(line) + 1
    return "\n".join(lines) + "\n\n"


# ---------------------------------------------------------------------------
# Multi-channel recall
# ---------------------------------------------------------------------------
RRF_K = 60
CHANNEL_DEPTH = 30
REL_FLOOR = 0.35          # drop hits under this share of the best score
WEAK_KEYWORD = 0.3        # a keyword-only hit under this share of the best one is noise
HOP_PARENTS = 3
HOP_MAX = 4
HUB_DEGREE = 60           # an entity linked to more memories than this isn't followed
_embed_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="jarvis-mem-embed")

recall_legacy = hybrid_recall


@dataclass
class RecallQuery:
    text: str
    now: float
    zone: Any
    context: str = ""
    limit: int = 6
    budget_chars: int = 2400


@dataclass
class RecallResult:
    hits: List[Hit]
    block: str
    trace: Dict[str, Any] = field(default_factory=dict)
    window: Optional[TimeWindow] = None


def _salience(c: Chunk, now: float) -> float:
    prox = 0.0
    if c.event_start:
        start = float(c.event_start)
        end = float(c.event_end or start)
        if start <= now <= end:
            prox = 1.0
        else:
            days = (start - now) / 86400.0
            if 0 <= days <= 14:
                prox = 1.0 - days / 14.0
            elif -3 <= (end - now) / 86400.0 < 0:
                prox = 0.5
    imp = c.importance if c.importance is not None else 5
    age = max(now - float(c.created_at or now), 0.0) / 86400.0
    factor = (1.0 + 0.6 * prox + 0.2 * (imp - 5) / 5.0 + 0.15 * math.exp(-age / 30.0)
              + 0.5 * (1 if c.pinned else 0) - 0.8 * (1 if c.valid_to else 0))
    return max(factor, 0.1)


def recall(store: MemoryStore, embedder: Embedder, q: RecallQuery, *, entity_index,
           namespace: str = GLOBAL_NS, candidate_ids=None) -> RecallResult:
    t0 = time.perf_counter()
    text = (q.text or "").strip()
    both = (text + " " + (q.context or "")).strip()
    if not both:
        return RecallResult([], "", {"ms": 0})
    only = set(candidate_ids) if candidate_ids is not None else None
    fut = _embed_pool.submit(embedder.embed_one, both)

    channels: Dict[str, List[str]] = {}
    kw = store.keyword_search(namespace, text or both, CHANNEL_DEPTH, only_ids=only)
    kw_score = dict(kw)
    kw_best = max(kw_score.values(), default=0.0)
    channels["keyword"] = [c for c, _ in kw]

    matched = entity_index.match(both) if entity_index is not None else []
    ent_ids = [m[0] for m in matched]
    ent_hits = [c for c in store.memories_for_entities(ent_ids, CHANNEL_DEPTH)
                if only is None or c in only]
    channels["entity"] = ent_hits

    win = None
    if text:
        try:
            win = time_window(text, datetime.fromtimestamp(q.now, q.zone))
        except Exception:
            win = None
    if win is not None:
        timed = store.ids_in_window(namespace, win.start, win.end, CHANNEL_DEPTH)
        events = store.event_entities_in_window(namespace, win.start, win.end)
        for c in store.memories_for_entities(events, CHANNEL_DEPTH):
            if c not in timed:
                timed.append(c)
        channels["time"] = [c for c in timed if only is None or c in only]

    try:
        vec = fut.result(timeout=5)
        channels["vector"] = [c for c, _ in store.vector_search(
            namespace, vec, embedder.signature, CHANNEL_DEPTH, only_ids=only)]
    except Exception as e:
        logger.warning("jarvis_memory vector arm failed: %s", e)
        channels["vector"] = []

    fused: Dict[str, float] = {}
    seen_in: Dict[str, set] = {}
    for name, ids in channels.items():
        for rank, cid in enumerate(ids, start=1):
            fused[cid] = fused.get(cid, 0.0) + 1.0 / (RRF_K + rank)
            seen_in.setdefault(cid, set()).add(name)
    chunks = {c.id: c for c in store.get_chunks(list(fused))}
    scored = []
    for cid, base in fused.items():
        c = chunks.get(cid)
        if c is None:
            continue
        if seen_in[cid] == {"keyword"} and kw_score.get(cid, 0.0) < WEAK_KEYWORD * kw_best:
            continue
        scored.append((cid, base * _salience(c, q.now)))
    scored.sort(key=lambda x: x[1], reverse=True)
    if scored:
        floor = scored[0][1] * REL_FLOOR
        scored = [x for x in scored if x[1] >= floor]
    scored = scored[: q.limit]

    # One hop: memories sharing an event / place / person with the best hits.
    hop = []
    top = [cid for cid, _ in scored[:HOP_PARENTS]]
    links = store.entities_for(top)
    parent_score = dict(scored)
    eids = sorted({e for cid in top for e, _ in links.get(cid, [])})
    degree = store.entity_degree(eids)
    have = {cid for cid, _ in scored}
    for cid in top:
        follow = [e for e, _ in links.get(cid, []) if degree.get(e, 0) <= HUB_DEGREE]
        for nid in store.memories_for_entities(follow, 10):
            if len(hop) >= HOP_MAX:
                break
            if nid in have or (only is not None and nid not in only):
                continue
            nc = chunks.get(nid) or next(iter(store.get_chunks([nid])), None)
            if nc is None or nc.valid_to:
                continue
            chunks[nid] = nc
            have.add(nid)
            hop.append((nid, parent_score[cid] * 0.5))
    final = scored + hop
    hits = [Hit(chunk=chunks[cid], score=sc) for cid, sc in final]
    block = format_recall_block(hits, q.budget_chars, zone=q.zone)
    ms = round((time.perf_counter() - t0) * 1000, 1)
    trace = {
        "channels": {k: v[:10] for k, v in channels.items()},
        "entities": [m[1] for m in matched],
        "window": win.label if win else "",
        "hits": [(cid, round(sc, 5)) for cid, sc in final],
        "hop": [cid for cid, _ in hop],
        "ms": ms,
    }
    return RecallResult(hits, block, trace, win)
