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


_SPECIFIC = re.compile(r"\$?\d[\d,.:]*(?:am|pm|%|k)?|\b[A-Z][\w'-]+", re.UNICODE)


def specifics(text: str) -> set:
    """Numbers, times, amounts and names in ``text`` (a capitalised word that
    doesn't start a sentence). Two memories that read alike but differ here —
    Tue vs Thu, $50 vs $15, Sam vs Priya — are different memories."""
    out = set()
    for m in _SPECIFIC.finditer(text or ""):
        word = m.group(0)
        before = (text[:m.start()].rstrip() or ".")[-1]
        if word[0].isupper() and before in ".!?:\n":
            continue  # a sentence's first word
        out.add(word.lower().rstrip(".,"))
    return out


def same_specifics(a: str, b: str) -> bool:
    return specifics(a) == specifics(b)


# A bracketed block of 40+ chars ending "]" + blank line; it may hold its own [brackets].
_INJECTED = re.compile(r"\A\s*\[.{40,}?\]\s*\n\s*\n", re.DOTALL)
# The web chat's working-directory tag, "[Workspace::v1: /root/workspace] ".
_WORKSPACE = re.compile(r"\A\s*\[Workspace::v1:\s*(?:\\.|[^\]\\])+\]\s*")
_STAMP = re.compile(r"\s*\((?:from an iMessage chat|overheard in a Live conversation)[^)]*\)")


def strip_injected(text: str) -> str:
    """His own words: drop the bracketed instruction blocks surfaces put in
    front of a turn ("[Voice mode — … rules …]\\n\\n", the workspace tag),
    however many."""
    text = text or ""
    while True:
        m = _WORKSPACE.match(text) or _INJECTED.match(text)
        if not m:
            return text.strip()
        text = text[m.end():]


# Greetings, thanks and acks: nothing in them to look up. Only these words —
# "who is he?" or "open it" are follow-ups, not small talk.
_SMALL_TALK = frozenset("""
hi hii hello hey heya hiya yo sup wassup whats what's whatsup up howdy morning afternoon
evening night gm gn good great nice cool awesome thanks thank thx ty ok okay k kk alright
lol lmao haha hehe bye cya later sir dude bro man jarvis you how how's hows are doing
going it
""".split())


def is_small_talk(text: str) -> bool:
    """True for "Hello", "Yooo", "What's up", "thanks!" — a message with no
    words worth recalling memories for (stretched letters count: "yooo" = "yo")."""
    words = re.findall(r"[a-z0-9']+", (text or "").lower().replace("’", "'"))
    if not words or len(words) > 6:
        return False
    return all(w in _SMALL_TALK or re.sub(r"(.)\1+", r"\1", w) in _SMALL_TALK for w in words)


def strip_stamp(text: str) -> str:
    """A memory's body without its "(from an iMessage chat with … UTC)" stamp."""
    return _STAMP.sub("", text or "")


def fts_query(text: str) -> str:
    """An FTS5 MATCH expression OR-ing the content words (quoted, so FTS
    operators in the text are inert). "" when nothing meaningful is left."""
    return " OR ".join(f'"{t}"' for t in content_tokens(text))
