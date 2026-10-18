"""His plain yes — or plain no — to a question Jarvis asked, read by the server.

Some actions run only on his own clear answer in the conversation, never on the model's say-so: car
commands (plugins/toyota/confirm.py) and calls, texts, emails and messages to other people on a voice
turn (agent/send_confirm.py). Both read his next message with these.

A yes is plain when nothing hedges it ("Yes, but…", "if…", a question) and the words after it are only
more yes, manners, or words naming what he was asked (``extra``). Anything else is not a yes: the
caller drops what was asked rather than guess.
"""
from __future__ import annotations

import re
from typing import Any, Iterable

_FILLER = re.compile(r"^(?:(?:hey\s+)?jarvis|um+|uh+|oh|well|so|and)\b[\s,.!-]*", re.I)
_YES = re.compile(
    r"^(?:yes|yeah|yea|yep|yup|ya|yah|aye|sure|ok(?:ay)?|fine|alright|all\s+right|confirm(?:ed)?|do\s+it|"
    r"go\s+ahead|go\s+for\s+it|affirmative|absolutely|definitely|of\s+course|correct|right|please|"
    r"sounds\s+good|let'?s\s+(?:do\s+it|go)|send\s+it)\b", re.I)
# Anything that makes it less than a plain yes: a no, a hold-on, a condition, a question.
_DOUBT = re.compile(
    r"\b(?:no|nope|nah|not|don'?t|do\s+not|never|cancel|stop|wait|hold\s+on|hang\s+on|never\s*mind|nevermind|"
    r"actually|maybe|later|hmm+|but|instead|unless|if|why|what|which|how|who|when|where|isn'?t|aren'?t|"
    r"shouldn'?t|wouldn'?t|can'?t|won'?t|didn'?t|doesn'?t)\b|\?", re.I)
_MAX_WORDS = 14
# What may follow the yes: more yes and manners ("Yes, please").
AFTER_YES = frozenset("""
    yes yeah yea yep yup ya yah aye sure ok okay fine alright right correct confirm confirmed absolutely
    definitely of course please thanks thank you sir jarvis go ahead for it do that now then let's lets
    send sounds good all and the my them both too also just um uh oh well so a to i is
""".split())
_NO = re.compile(r"^(?:no|nope|nah|cancel|stop|never\s*mind|nevermind|forget\s+it|don'?t|do\s+not)\b", re.I)
# A plain no: the no and nothing that changes what was asked ("No, text Sarah" is a change, not a no).
_AFTER_NO = frozenset("""
    no nope nah not don't dont do cancel it that this stop never mind nevermind forget thanks thank you sir
    jarvis please send call text email message the him her them now
""".split())
# The messaging gateway's wrappers around his own words (gateway/run.py): a voice note's transcript,
# and the message he's replying to; and the web app's workspace tag on every chat turn.
_VOICE_NOTE = re.compile(r'^\[The user sent a voice message~ Here\'s what they said: "(.*)"\]$', re.S)
_REPLYING = re.compile(r'^\[Replying to: ".*"\]\n\n', re.S)
_WORKSPACE = re.compile(r"^\s*\[Workspace::v1:\s*(?:\\.|[^\]\\])+\]\s*")


def text_of(content: Any) -> str:
    """The words of a message: a string, or the text parts of a multimodal list."""
    if isinstance(content, list):
        return " ".join(str(p.get("text") or "") for p in content
                        if isinstance(p, dict) and p.get("type") in (None, "text", "input_text"))
    return str(content or "")


def own_words(user_message: Any) -> str:
    """His words in a turn's message, out of the gateway's and the web app's wrappers."""
    t = _WORKSPACE.sub("", text_of(user_message).strip(), count=1).strip()
    t = _REPLYING.sub("", t, count=1).strip()
    voice = _VOICE_NOTE.match(t)
    return voice.group(1).strip() if voice else t


def _without_echo(t: str, echo: Any) -> str:
    """Drop the end of the question the mic caught before his answer ("send it? Yes")."""
    heard = set(re.findall(r"[a-z']+", text_of(echo).lower()))
    if not heard:
        return t
    asked = re.match(r"([^?]*)\?\s*(.*)$", t, re.S)
    if asked and all(w in heard for w in re.findall(r"[a-z']+", asked.group(1).lower())):
        t = asked.group(2)
    for _ in range(4):
        first = re.match(r"([A-Za-z']+)[\s,.?!-]*", t)
        if not first or first.group(1).lower() not in heard or _YES.match(t):
            break
        t = t[first.end():]
    return t


def _without_filler(t: str) -> str:
    while True:
        stripped = _FILLER.sub("", t, count=1)
        if stripped == t:
            return t
        t = stripped


def is_plain_yes(words: Any, extra: Iterable[str] = (), echo: Any = "") -> bool:
    """A plain yes ("Yes.", "Yeah, do it", "Go ahead"): nothing that hedges, and nothing after it but
    more yes, manners and ``extra`` (words naming what he was asked). ``echo``: the question he was
    asked; a mic that caught its last words doesn't spoil the yes."""
    t = _without_filler(_without_echo(text_of(words).replace("’", "'").strip(), echo))
    if not t or len(t.split()) > _MAX_WORDS or not _YES.match(t) or _DOUBT.search(t):
        return False
    allowed = AFTER_YES.union(extra)
    return all(word in allowed for word in re.findall(r"[a-z']+|\d+", t.lower()))


def is_plain_no(words: Any) -> bool:
    """A plain no ("No.", "Nope, don't send it", "Cancel") — not a no that changes what was asked."""
    t = _without_filler(text_of(words).replace("’", "'").strip())
    if not t or len(t.split()) > _MAX_WORDS or not _NO.match(t):
        return False
    return all(word in _AFTER_NO for word in re.findall(r"[a-z']+|\d+", t.lower()))
