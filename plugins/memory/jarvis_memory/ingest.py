"""Hot-path ingestion: cheap deterministic scoring, chunking, and capture.

No LLM and no per-turn latency budget here — the heavier LLM extraction /
summarization pipeline arrives in Phase 2. This module just decides what is
worth keeping (cheap signal blend, drop threshold copied from openhuman),
chunks the text, embeds the kept pieces, and stores them.
"""
from __future__ import annotations

import logging
import re
import time
from typing import List

from .embed import Embedder
from .store import GLOBAL_NS, MemoryStore

logger = logging.getLogger(__name__)

DROP_THRESHOLD = 0.3  # openhuman default

# Greetings / acknowledgements / generic assistant openers that carry no durable
# value — dropped before storage. (A coarse stand-in until Phase-2 LLM triage.)
_TRIVIAL_EXACT = {
    "hi", "hello", "hey", "yo", "sup", "thanks", "thank you", "ty", "ok", "okay", "k",
    "cool", "nice", "great", "awesome", "perfect", "got it", "sure", "yes", "yep",
    "no", "nope", "yeah", "oh", "hmm", "huh", "done", "np", "no problem", "good",
    "hi there", "hello there", "good morning", "good evening", "goodbye", "bye",
}
_TRIVIAL_PHRASES = (
    "how can i help", "how may i help", "what can i do for you",
    "is there anything else", "let me know if",
)


def is_trivial(body: str) -> bool:
    t = re.sub(r"[^\w\s]", "", (body or "").lower()).strip()
    t = re.sub(r"\s+", " ", t)
    if not t:
        return True
    if t in _TRIVIAL_EXACT:
        return True
    # generic assistant openers ("Hi Pranav! How can I help?")
    if any(p in t for p in _TRIVIAL_PHRASES) and len(t.split()) <= 9:
        return True
    return False


def cheap_score(body: str, source: str = "chat") -> float:
    """Deterministic, no-LLM admission score in [0,1].

    Phase-1 subset of openhuman's signal blend: length + lexical diversity +
    a turn-interaction bias. Trivial utterances score below DROP_THRESHOLD.
    """
    if is_trivial(body):
        return 0.0
    words = re.findall(r"\w+", (body or "").lower())
    n = len(words)
    if n < 3:
        return 0.0
    uniq = len(set(words))
    length_sig = min(n / 40.0, 1.0)
    unique_sig = uniq / n
    # Smaller constant than the original 0.3 so the blended signal can actually
    # fall below DROP_THRESHOLD (the constant + threshold previously made the
    # score-based drop a no-op). Real importance filtering arrives with the
    # Phase-2 LLM triage band.
    return max(0.0, min(1.0, 0.4 * length_sig + 0.35 * unique_sig + 0.1))


def chunk_text(text: str, max_chars: int = 1500) -> List[str]:
    out: List[str] = []
    for para in re.split(r"\n\s*\n", (text or "").strip()):
        para = para.strip()
        if not para:
            continue
        if len(para) <= max_chars:
            out.append(para)
        else:
            for i in range(0, len(para), max_chars):
                piece = para[i:i + max_chars].strip()
                if piece:
                    out.append(piece)
    return out


def ingest_turn(store: MemoryStore, embedder: Embedder, namespace: str,
                user_content: str, assistant_content: str, source: str = "chat",
                roles=("user", "assistant")) -> List[str]:
    candidates = []
    by_role = {"user": user_content or "", "assistant": assistant_content or ""}
    for role in roles:
        content = by_role.get(role, "")
        for piece in chunk_text(content):
            sc = cheap_score(piece, source)
            if sc >= DROP_THRESHOLD:
                candidates.append((role, piece, sc))
    if not candidates:
        return []
    try:
        embs = list(embedder.embed([b for _, b, _ in candidates]))
    except Exception as e:
        logger.warning("jarvis_memory embed failed during ingest (storing without vectors): %s", e)
        embs = [None] * len(candidates)
    # Never let a short/long embedder result silently drop chunks via zip().
    if len(embs) != len(candidates):
        logger.warning("jarvis_memory embedder returned %d vectors for %d inputs; padding",
                       len(embs), len(candidates))
        embs = (embs + [None] * len(candidates))[:len(candidates)]
    ids = []
    for (role, body, sc), emb in zip(candidates, embs):
        use_emb = emb if (emb and len(emb)) else None  # skip empty/zero-length vectors
        ids.append(store.add_chunk(
            namespace=namespace or GLOBAL_NS, body=body, source=f"{source}:{role}",
            created_at=time.time(), score=sc, tags=role,
            embedding=use_emb, signature=embedder.signature if use_emb else None,
            dim=embedder.dim if use_emb else None,
        ))
    return ids
