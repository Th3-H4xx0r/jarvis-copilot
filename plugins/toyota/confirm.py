"""His yes in the conversation for a car command, in place of Face ID.

Pranav (2026-10-17): asking Jarvis for the car — by voice on any surface, or typed in chat — should
"just ask for a confirmation then do the actions", not send a Face ID card to his phone. The server
checks the yes, not the model: toyota_command only notes what it would run and has Jarvis ask; at
the start of his next turn in that chat (the pre_llm_call hook — the turn's message as he sent it,
never model-written text) a clear yes runs it, and anything else drops it.

A yes only counts when Jarvis's last reply actually asked about those commands, and names nothing
else ("Okay, lock it" never unlocks). Runs with nobody there to answer — scheduled jobs, subagents,
/background tasks, harness background jobs, Live passes — keep the Face ID approval on his iPhone
(tools.py), and so does the Car page.
"""
from __future__ import annotations

import concurrent.futures
import re
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

from plugins.toyota import service
from plugins.toyota.approver import TITLES
from plugins.toyota.car import CarError, NotSignedIn, ToyotaCar
from plugins.toyota.ha import HAClient, HAError

ANSWER_WITHIN = 120.0   # seconds his yes may take
RUN_WAIT = 15.0         # seconds his yes turn waits for the car before saying it's on its way
_MAX_CHATS = 500
# Task ids of runs with nobody to answer: subagents ("sa-…", "subagent-…"), Live passes
# ("live-…"), /background tasks ("bg_…"); harness background jobs are "<chat>~<node>".
_UNATTENDED_PREFIXES = ("sa-", "subagent-", "live-", "bg_")
_UNATTENDED_PLATFORMS = frozenset({"cron"})

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
# What may follow the yes: more yes and manners ("Yes, please")...
_AFTER_YES = frozenset("""
    yes yeah yea yep yup ya yah aye sure ok okay fine alright right correct confirm confirmed absolutely
    definitely of course please thanks thank you sir jarvis go ahead for it do that now then let's lets
    send sounds good all and the my them both too also just um uh oh well so a to i is
""".split())
# ...and words naming what he was asked — only those ("Sure, unlock it" to "Unlock the car?", never
# "Okay, lock it"). Anything else ("yeah, I was thinking about it") is not a plain yes: Jarvis asks again.
_SAYS: dict[str, frozenset[str]] = {k: frozenset(v.split()) for k, v in {
    "start": "start car engine up remote",
    "lock": "lock car door doors up",
    "unlock": "unlock car door doors open",
    "trunk_lock": "lock trunk",
    "trunk_unlock": "unlock open pop trunk",
    "lights": "turn on lights headlights light flash car",
    "horn": "sound honk horn car",
    "buzzer": "sound buzz buzzer car",
    "hazards_on": "turn on hazards hazard flashers car",
    "hazards_off": "turn off hazards hazard flashers car",
}.items()}
# Jarvis's question has to name each command (the reply he actually heard) — a "yes" to something
# else ("Want me to draft a reply?") must never run a car command queued behind it.
_ASKED: dict[str, tuple[re.Pattern, ...]] = {k: tuple(re.compile(c, re.I) for c in v) for k, v in {
    "start": (r"\bstart",),
    "lock": (r"\block",),
    "unlock": (r"\bunlock",),
    "trunk_lock": (r"\btrunk", r"\block"),
    "trunk_unlock": (r"\btrunk", r"\b(?:unlock|open|pop)"),
    "lights": (r"\b(?:head)?lights?\b",),
    "horn": (r"\b(?:horn|honk)",),
    "buzzer": (r"\bbuzz",),
    "hazards_on": (r"\bhazard|\bflashers", r"^(?!.*\boff\b)"),
    "hazards_off": (r"\bhazard|\bflashers", r"\boff\b"),
}.items()}
_QUESTION = re.compile(r"[^.?!\n]*\?")
# The messaging gateway's wrappers around his own words (gateway/run.py): a voice note's transcript,
# and the message he's replying to. A group chat's "[Name] …" is left alone — others can't confirm.
_VOICE_NOTE = re.compile(r'^\[The user sent a voice message~ Here\'s what they said: "(.*)"\]$', re.S)
_REPLYING = re.compile(r'^\[Replying to: ".*"\]\n\n', re.S)


@dataclass
class _Turn:
    seq: int
    text: str
    platform: str
    at: float
    reply: str = ""              # Jarvis's reply just before it: a re-run of the same turn has the same one
    length: int = 0              # ...and the same conversation length
    note: str | None = None      # what this turn was told about the car (re-sent if the turn re-runs)


@dataclass
class _Pending:
    commands: list[str]
    seq: int                     # the turn that asked
    at: float


@dataclass
class _Ran:
    seq: int
    results: dict[str, str] = field(default_factory=dict)


_lock = threading.Lock()
# By chat (the session id: a turn's task id can be new every turn, e.g. the TUI's) ...
_turns: "OrderedDict[str, _Turn]" = OrderedDict()
_pending: dict[str, _Pending] = {}
_ran: dict[str, _Ran] = {}
# ... and each run's task id → its chat, or None for a run with nobody to answer.
_chat_of: "OrderedDict[str, str | None]" = OrderedDict()
_clock: Callable[[], float] = time.monotonic


def _text(content: Any) -> str:
    """The words of a message: a string, or the text parts of a multimodal list."""
    if isinstance(content, list):
        return " ".join(str(p.get("text") or "") for p in content
                        if isinstance(p, dict) and p.get("type") in (None, "text", "input_text"))
    return str(content or "")


def own_words(user_message: Any) -> str:
    """His words in a turn's message, out of the messaging gateway's wrappers."""
    t = _text(user_message).strip()
    t = _REPLYING.sub("", t, count=1).strip()
    voice = _VOICE_NOTE.match(t)
    return voice.group(1).strip() if voice else t


def is_yes(words: Any, commands: Iterable[str] = (), echo: Any = "") -> bool:
    """A plain yes ("Yes.", "Yeah, do it", "Go ahead", "Sure, unlock it") — nothing that hedges, and
    nothing naming a command other than `commands`, the ones he was asked about. `echo`: the
    question he was asked; a mic that caught its last words ("car? Yes") doesn't spoil the yes."""
    t = _text(words).replace("’", "'").strip()
    heard = set(re.findall(r"[a-z']+", _text(echo).lower()))
    for _ in range(4):
        first = re.match(r"([A-Za-z']+)[\s,.?!-]*", t)
        if not first or first.group(1).lower() not in heard or _YES.match(t):
            break
        t = t[first.end():]
    while True:
        stripped = _FILLER.sub("", t, count=1)
        if stripped == t:
            break
        t = stripped
    if not t or len(t.split()) > _MAX_WORDS or not _YES.match(t) or _DOUBT.search(t):
        return False
    allowed = _AFTER_YES.union(*(_SAYS.get(c, ()) for c in commands))
    return all(word in allowed for word in re.findall(r"[a-z']+|\d+", t.lower()))


def was_asked(reply: Any, commands: Iterable[str]) -> bool:
    """Whether Jarvis's reply asks him about every one of `commands` (in its questions)."""
    asked = " ".join(_QUESTION.findall(_text(reply)))
    return bool(asked) and all(all(c.search(asked) for c in _ASKED.get(name, (re.compile("$^"),)))
                               for name in commands)


def question(commands: Iterable[str]) -> str:
    """"Unlock the car?" / "Unlock the car and start the car?" """
    titles = [TITLES.get(c, c) for c in commands]
    if not titles:
        return ""
    rest = [t[:1].lower() + t[1:] for t in titles[1:]]
    if not rest:
        return titles[0] + "?"
    return f"{', '.join([titles[0], *rest[:-1]])} and {rest[-1]}?"


def _unattended() -> bool:
    """Inside tools.approval.unattended_run(): a gateway harness node working after its turn ended."""
    try:
        from tools.approval import _unattended_run
        return bool(_unattended_run.get())
    except Exception:
        return False


def _unattended_task(task_id: str) -> bool:
    return "~" in task_id or task_id.startswith(_UNATTENDED_PREFIXES) or _unattended()


def _chat(task_id: Any) -> str | None:
    tid = str(task_id or "")
    if not tid or _unattended_task(tid):
        return None
    with _lock:
        return _chat_of.get(tid)


def conversational(task_id: Any) -> bool:
    """Whether this run is a chat he's in, so his next message can answer Jarvis's question."""
    return _chat(task_id) is not None


def ask(task_id: Any, command: str) -> list[str]:
    """Note `command` for his answer to this turn's question; every command it covers, in order."""
    chat = _chat(task_id) or str(task_id)
    now = _clock()
    with _lock:
        turn = _turns.get(chat)
        seq = turn.seq if turn else 0
        pending = _pending.get(chat)
        if pending is None or pending.seq != seq:
            pending = _pending[chat] = _Pending([], seq, now)
        if command not in pending.commands:
            pending.commands.append(command)
        pending.at = now
        return list(pending.commands)


def ran_this_turn(task_id: Any, command: str) -> str | None:
    """How `command` went if his yes at the start of this turn already ran it."""
    chat = _chat(task_id)
    with _lock:
        turn, ran = _turns.get(chat or ""), _ran.get(chat or "")
        if turn is None or ran is None or ran.seq != turn.seq:
            return None
        return ran.results.get(command)


def run_commands(commands: list[str], wait: float = RUN_WAIT) -> dict[str, str]:
    """Run what he said yes to, in order. Waits up to `wait` seconds for the car; a command still
    going then is left to finish and reported as on its way."""
    results: dict[str, str] = {}

    async def go() -> None:
        car = ToyotaCar(HAClient())
        try:
            await service.require_signed_in(car.ha)
        except (NotSignedIn, HAError) as exc:
            for name in commands:
                results[name] = f"not sent: {exc}"
            return
        for name in commands:
            try:
                results[name] = (await car.command(name, approved=True))["result"]
            except (NotSignedIn, CarError, HAError) as exc:
                results[name] = f"failed: {exc}"

    pool = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="car-yes")
    future = pool.submit(service.run, go())
    pool.shutdown(wait=False)
    try:
        future.result(timeout=wait)
    except concurrent.futures.TimeoutError:
        pass
    except Exception as exc:     # never let the car break his turn
        return {name: results.get(name) or f"failed: {exc}" for name in commands}
    return {name: results.get(name) or "on its way — Toyota hasn't confirmed it yet (it may still happen)"
            for name in commands}


def _report(asked: str, results: dict[str, str]) -> str:
    done = "; ".join(f"{TITLES.get(c, c)} → {r}" for c, r in results.items())
    return (f"[Car: he said yes to “{asked}”, so the server already ran it: {done}. Tell him how it went "
            "in a few words. Don't call toyota_command for it again, and never repeat a car command on "
            "your own.]")


def _last_reply(history: Any) -> str:
    for m in reversed(history if isinstance(history, list) else []):
        if isinstance(m, dict) and m.get("role") == "assistant" and m.get("content"):
            return _text(m.get("content")).strip()
    return ""


def _remember_task(task_id: str, chat: str | None) -> None:
    _chat_of[task_id] = chat
    _chat_of.move_to_end(task_id)
    while len(_chat_of) > _MAX_CHATS * 4:
        _chat_of.popitem(last=False)


def on_turn(task_id: Any, user_message: Any, platform: Any = "", history: Any = None,
            run: Callable[[list[str]], dict[str, str]] | None = None, session_id: Any = None) -> str | None:
    """Record his turn; when it answers Jarvis's car question, run or drop what was asked.
    `history` is the conversation so far (for Jarvis's last reply); `session_id` the chat, when the
    task id isn't stable across its turns. Returns a note for this turn's model call, or None."""
    tid = str(task_id or session_id or "")
    if not tid:
        return None
    if _unattended_task(tid) or str(platform or "") in _UNATTENDED_PLATFORMS:
        # Nobody's there to answer; and its text (often model-written) never touches a chat's question.
        with _lock:
            _remember_task(tid, None)
        return None
    chat = str(session_id or tid)
    words = _text(user_message).strip()
    reply = _last_reply(history)
    length = len(history) if isinstance(history, list) else 0
    now = _clock()
    with _lock:
        _remember_task(tid, chat)
        prev = _turns.get(chat)
        if (prev is not None and words == prev.text and reply == prev.reply and length == prev.length
                and now - prev.at < ANSWER_WITHIN):
            # The same turn again (a failed turn re-runs with his message): not a new answer.
            return prev.note
        turn = _Turn((prev.seq if prev else 0) + 1, words, str(platform or ""), now, reply, length)
        _turns[chat] = turn
        _turns.move_to_end(chat)
        while len(_turns) > _MAX_CHATS:
            old, _ = _turns.popitem(last=False)
            _pending.pop(old, None)
            _ran.pop(old, None)
        pending = _pending.pop(chat, None)
    if pending is None:
        return None
    asked = question(pending.commands)
    heard = " ".join(_QUESTION.findall(reply))
    if not was_asked(reply, pending.commands):
        note = (f"[Car: “{asked}” was never put to him in your last reply, so it was cancelled and nothing "
                "was sent. If he wants it, call toyota_command again and ask him.]")
    elif not is_yes(own_words(words), pending.commands, echo=heard):
        note = (f"[Car: his reply isn't a clear yes to “{asked}”, so nothing was sent and that request is "
                "cancelled. Call toyota_command again only if he asks for it again.]")
    elif now - pending.at > ANSWER_WITHIN:
        note = (f"[Car: “{asked}” went unanswered for over 2 minutes, so it was cancelled and nothing was "
                "sent. If he still wants it, call toyota_command again so he can confirm.]")
    else:
        results = (run or run_commands)(list(pending.commands))
        note = _report(asked, results)
        with _lock:
            _ran[chat] = _Ran(turn.seq, dict(results))
    with _lock:
        turn.note = note
    return note


def on_pre_llm_call(*, task_id: str = "", session_id: str = "", user_message: Any = None,
                    platform: str = "", conversation_history: Any = None, **_: Any) -> dict | None:
    """pre_llm_call hook: fires once per turn, before the model, with the turn's own message."""
    note = on_turn(task_id or session_id, user_message, platform, conversation_history,
                   session_id=session_id or None)
    return {"context": note} if note else None


def reset_for_tests() -> None:
    with _lock:
        _turns.clear()
        _pending.clear()
        _ran.clear()
        _chat_of.clear()
