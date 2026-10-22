"""Keyword-query building for the FTS5 arm: content words only.

Filler words ("can", "you", "the", "open") matched almost every memory and,
scored by rank position, handed whichever row FTS listed first a large bonus
however weakly it matched. Dropping them leaves the words that carry meaning.
"""
from __future__ import annotations

import re

STOPWORDS = frozenset("""
a about above after again against all am an and any are as at be because been before
being below between both but by can could did do does doing down during each few for
from further had has have having he her here hers herself him himself his how i if in
into is it its itself just me more most my myself no nor not now of off on once only or
other our ours ourselves out over own same she should so some such than that the their
theirs them themselves then there these they this those through to too under until up
very was we were what when where which while who whom why will with would you your
yours yourself yourselves im ive id youre its lets let get got go going gonna wanna
please pls hey hi jarvis open show tell
okay ok yeah yes also really still just thing things something anything
""".split())


def content_tokens(text: str):
    """Lower-cased word tokens of ``text`` minus stopwords and 1-letter tokens."""
    toks = re.findall(r"\w+", (text or "").lower(), flags=re.UNICODE)
    out, seen = [], set()
    for t in toks:
        if len(t) < 2 or t in STOPWORDS or t in seen:
            continue
        seen.add(t)
        out.append(t)
    return out


def fts_query(text: str) -> str:
    """An FTS5 MATCH expression OR-ing the content words (quoted, so FTS
    operators in the text are inert). "" when nothing meaningful is left."""
    return " OR ".join(f'"{t}"' for t in content_tokens(text))
