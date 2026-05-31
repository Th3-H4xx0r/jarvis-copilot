"""Hybrid (vector + keyword) recall and budgeted block formatting.

Phase 1 uses openhuman's no-graph fusion weights (vector 0.65 / keyword 0.35).
The graph + episodic + freshness arms and the query-less recall blend arrive in
Phase 3.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import List

from .embed import Embedder
from .store import Chunk, GLOBAL_NS, MemoryStore

logger = logging.getLogger(__name__)

VECTOR_WEIGHT = 0.65
KEYWORD_WEIGHT = 0.35


@dataclass
class Hit:
    chunk: Chunk
    score: float


def hybrid_recall(store: MemoryStore, embedder: Embedder, query: str,
                  namespace: str = GLOBAL_NS, limit: int = 5,
                  min_relevance: float = 0.0) -> List[Hit]:
    vec_hits = {}
    try:
        qv = embedder.embed_one(query)
        for cid, cos in store.vector_search(namespace, qv, embedder.signature, limit * 4):
            vec_hits[cid] = (cos + 1.0) / 2.0  # map [-1,1] -> [0,1]
    except Exception as e:
        logger.warning("jarvis_memory vector arm failed: %s", e)
    kw_hits = dict(store.keyword_search(namespace, query, limit * 4))
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


def format_recall_block(hits: List[Hit], max_context_chars: int = 2000) -> str:
    """Render hits as a memory block, budgeted by char count.

    Always includes the header + at least the top hit when any hits exist;
    additional hits are added until the budget would be exceeded.
    """
    if not hits:
        return ""
    header = "[Long-term memory]"
    lines = [header]
    used = len(header)
    for i, h in enumerate(hits):
        body = " ".join(h.chunk.body.split())
        line = f"- {body}"
        if i > 0 and used + len(line) + 1 > max_context_chars:
            break
        lines.append(line)
        used += len(line) + 1
    return "\n".join(lines) + "\n\n"
