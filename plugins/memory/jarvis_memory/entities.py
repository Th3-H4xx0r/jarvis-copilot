"""Names in text → the people, places, events and topics in the memory map.

An in-memory alias table (canonical names + aliases, plus unique first names
for people) rebuilt whenever the store's entity version moves. Matching is
whole-word and longest-first, so "F1 US Grand Prix" wins over "US".
"""
from __future__ import annotations

import re
import threading
from typing import Dict, List, Optional, Set, Tuple

from .textq import STOPWORDS

_MAX_NGRAM = 5


def _norm(text: str) -> List[str]:
    return re.findall(r"\w+", (text or "").lower(), flags=re.UNICODE)


class EntityIndex:
    def __init__(self, store, namespace: str):
        self._store = store
        self._ns = namespace
        self._version = None
        self._lock = threading.Lock()
        self._alias: Dict[str, Set[str]] = {}
        self._first: Dict[str, Set[str]] = {}
        self._types: Dict[str, str] = {}

    def refresh(self) -> None:
        version = self._store.entity_version()
        with self._lock:
            if version == self._version:
                return
            alias: Dict[str, Set[str]] = {}
            first: Dict[str, Set[str]] = {}
            types: Dict[str, str] = {}
            for e in self._store.all_entities(self._ns):
                types[e["id"]] = e["type"]
                for name in [e["canonical"]] + list(e.get("aliases") or []):
                    toks = _norm(name)
                    if toks:
                        alias.setdefault(" ".join(toks), set()).add(e["id"])
                toks = _norm(e["canonical"])
                if e["type"] == "person" and len(toks) >= 2:
                    first.setdefault(toks[0], set()).add(e["id"])
            self._alias, self._first, self._types = alias, first, types
            self._version = version

    def entity_type(self, entity_id: str) -> str:
        return self._types.get(entity_id, "")

    def match(self, text: str) -> List[Tuple[str, str, int]]:
        """``(entity_id, matched words, weight=word count)`` for each entity
        named in ``text``, first mention first. Ambiguous names are skipped."""
        self.refresh()
        toks = _norm(text)
        out: List[Tuple[str, str, int]] = []
        seen: Set[str] = set()
        i = 0
        while i < len(toks):
            hit = None
            for n in range(min(_MAX_NGRAM, len(toks) - i), 0, -1):
                phrase = " ".join(toks[i:i + n])
                if n == 1 and (len(phrase) < 3 or phrase in STOPWORDS):
                    continue
                ids = self._alias.get(phrase)
                if not ids and n == 1:
                    ids = self._first.get(phrase)
                if ids and len(ids) == 1:
                    hit = (next(iter(ids)), phrase, n)
                    break
            if hit:
                if hit[0] not in seen:
                    seen.add(hit[0])
                    out.append(hit)
                i += hit[2]
            else:
                i += 1
        return out

    def resolve(self, name: str, type: str = "") -> Optional[str]:
        """The one entity ``name`` refers to (of ``type`` when given), else None."""
        self.refresh()
        toks = _norm(name)
        if not toks:
            return None
        want = (type or "").lower()

        def pick(ids):
            ids = [i for i in (ids or ()) if not want or self._types.get(i) == want]
            return ids[0] if len(ids) == 1 else None

        found = pick(self._alias.get(" ".join(toks)))
        if found is None and len(toks) == 1 and want in ("", "person"):
            found = pick(self._first.get(toks[0]))
        return found
