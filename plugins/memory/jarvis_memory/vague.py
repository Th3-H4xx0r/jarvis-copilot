"""Vague references — "the venue", "text him", "go there" — resolved only
when the brief, the recent turns and the recalled memories don't already
name what's meant. Then one quick memory-model call says what it most likely
is: confident → Jarvis acts and says what it picked; not → it asks.
"""
from __future__ import annotations

import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field
from typing import Callable, List, Optional

logger = logging.getLogger(__name__)

# Definite nouns that point at a specific thing he expects Jarvis to know,
# with the map roles that would name it.
NOUNS = {
    "venue": ("venue", "place"), "place": ("place", "venue"), "restaurant": ("place", "venue"),
    "hotel": ("place", "venue", "booking"), "airport": ("place",), "office": ("place",),
    "event": ("event",), "race": ("event",), "game": ("event",), "show": ("event",),
    "concert": ("event",), "party": ("event",), "trip": ("event",), "meeting": ("event",),
    "appointment": ("event",), "flight": ("event", "booking"), "reservation": ("booking",),
}
_DEFINITE = re.compile(r"\bthe (" + "|".join(NOUNS) + r")\b", re.IGNORECASE)
_PRONOUN = re.compile(r"\b(?:text|call|message|email|tell|ask|remind|ping|invite)\s+(him|her|them)\b",
                      re.IGNORECASE)
_THERE = re.compile(r"\b(?:navigate|directions|drive|take me|go|get me|route|head)\b[^.?!]*\b(there|that place)\b",
                    re.IGNORECASE)

_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="jarvis-mem-vague")


@dataclass
class Resolution:
    referent: str
    confident: bool
    memory_ids: List[str] = field(default_factory=list)
    alternatives: List[str] = field(default_factory=list)


def _covered(word: str, *texts: str) -> bool:
    return any(re.search(rf"\b{re.escape(word)}\b", t or "", re.IGNORECASE) for t in texts)


def needs_resolution(text: str, brief: str, context: str, hits) -> Optional[str]:
    """The vague phrase in ``text`` nothing else resolves, or None."""
    top = list(hits or [])[:3]
    bodies = " ".join(h.chunk.body for h in top)
    slots = " · ".join(h.chunk.slots for h in top if h.chunk.slots)
    m = _DEFINITE.search(text or "")
    if m:
        noun = m.group(1).lower()
        if _covered(noun, brief, context, bodies):
            return None
        if any(re.search(rf"(^|· ){role}:", slots) for role in NOUNS[noun]):
            return None
        return f"the {noun}"
    m = _PRONOUN.search(text or "") or _THERE.search(text or "")
    if m:
        return None if (context or "").strip() else m.group(1).lower()
    return None


PROMPT = """Pranav asked his assistant: "{text}"
What does "{phrase}" most likely refer to? Use what's going on in his life, the recent conversation and the
memories below. Answer ONLY with JSON:
{{"referent": "the specific thing (name + what it is)", "confident": true|false,
  "alternatives": ["other likely options when not confident"], "memory_ids": ["ids that back it"]}}
Be confident only when one option clearly wins.

What's going on:
{brief}

Recent conversation:
{context}

Memories:
{memories}
"""


def resolve(phrase: str, text: str, brief: str, context: str, hits, *,
            complete: Optional[Callable[[str, int], str]] = None,
            timeout_s: float = 1.2) -> Optional[Resolution]:
    if complete is None:
        from . import llm
        complete = llm.complete
    memories = "\n".join(f"- {h.chunk.id}: {' '.join(h.chunk.body.split())[:220]}"
                         + (f" [{h.chunk.slots}]" if h.chunk.slots else "")
                         for h in list(hits or [])[:8]) or "- (none)"
    prompt = PROMPT.format(text=text, phrase=phrase, brief=(brief or "(nothing)")[:2500],
                           context=(context or "(none)")[:1200], memories=memories)
    fut = _pool.submit(complete, prompt, 300)
    try:
        reply = fut.result(timeout=timeout_s)
    except FutureTimeout:
        logger.info("jarvis_memory: resolving %r took over %.1fs; skipped", phrase, timeout_s)
        return None
    except Exception as exc:
        logger.info("jarvis_memory: resolving %r failed (%s)", phrase, exc)
        return None
    m = re.search(r"\{.*\}", reply or "", re.DOTALL)
    try:
        data = json.loads(m.group(0)) if m else {}
    except ValueError:
        return None
    referent = str(data.get("referent") or "").strip()
    alts = [str(a).strip() for a in data.get("alternatives") or [] if str(a).strip()]
    if not referent and not alts:
        return None
    return Resolution(referent=referent, confident=bool(data.get("confident")) and bool(referent),
                      memory_ids=[str(i) for i in data.get("memory_ids") or []][:5], alternatives=alts[:3])


def note(phrase: str, res: Resolution) -> str:
    if res.confident:
        return f'[Likely meaning] "{phrase}" = {res.referent} — act on it and say what you picked.'
    options = res.alternatives or ([res.referent] if res.referent else [])
    return (f'[Unclear] "{phrase}" could be ' + " or ".join(options)
            + " — ask a quick either/or before acting.")
