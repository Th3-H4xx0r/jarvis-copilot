"""Calls, texts, emails and messages to other people wait for his yes on a voice turn.

Pranav (2026-10-18): "for actions like calling and texts … show a popup for confirmation (full contact
name + contact image + message) … jarvis should say the confirmation with summary … keep the mic open
so that I can … reply yes or no, or with any corrections and then do it. … a button to send … which
basically is saying yes, and … an X button saying no." His picks: every voice surface (typed chat sends
as before); calls, texts, emails and other-app messages.

On a voice turn the dispatcher (model_tools.handle_function_call) hands such a call to ``gate``: it is
noted, not run, the turn's iPhone shows a card (the server-only phone skill ``confirm_card``), and the
model is told to ask. At the start of his next turn in that chat (``on_turn``, from
agent/conversation_loop.py — his own words, never model text) a plain yes runs it before the model
answers; a plain no, a correction, a yes to some other question, or two minutes of nothing drops it.
The card's Send / ✕ are his "Yes." / "No." on the voice session. Car commands work the same way
(plugins/toyota/confirm.py); both read the answer with agent/spoken_yes.py.

Typed chat turns (his ask, same day: "show a card with the contact name, profile picture, along with
the message to send and add a send button … for the chat surfaces … mac, ios, and web"; his pick: the
turn pauses until he taps): the chat streaming the turn shows the card as an ``approval`` of kind
"send" (tools.approval.ask_gateway) with the name and photo from his iPhone's contacts, and the tool
runs only on its Send. Turns with no chat on screen (messaging platforms, scripts) send as before.
"""
from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
import uuid
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable, Optional
from urllib.parse import parse_qs, unquote, urlsplit

from agent.spoken_yes import is_plain_no, is_plain_yes, own_words, text_of

logger = logging.getLogger(__name__)

ANSWER_WITHIN = 120.0  # seconds his answer may take
_MAX_CHATS = 500
# Task ids of runs with nobody to answer: subagents, Live passes, /background tasks; harness
# background jobs are "<chat>~<node>" (the same list as plugins/toyota/confirm.py).
_UNATTENDED_PREFIXES = ("sa-", "subagent-", "live-", "bg_")
_QUESTION = re.compile(r"[^.?!\n]*\?")

# Jarvis's question has to be about this (the reply he heard) — a yes to "Want the weather too?"
# never sends a text queued behind it.
_ASKED = {
    "call": re.compile(r"\b(?:call|ring|dial|phone|facetime)", re.I),
    "text": re.compile(r"\b(?:send|text|message|imessage|sms)", re.I),
    "email": re.compile(r"\b(?:send|e-?mail|mail)", re.I),
    "message": re.compile(r"\b(?:send|message|text|whatsapp|telegram|dm)", re.I),
}
# Words that may follow his yes for each kind ("Yes, call him"; the words of Jarvis's question
# count too: "Yeah, send it to Shabd").
_SAYS = {
    "call": frozenset("call him her them dial ring now".split()),
    "text": frozenset("send text it message him her them that".split()),
    "email": frozenset("send email mail it him her them that".split()),
    "message": frozenset("send message text it him her them that".split()),
}
_VIA = {"device_messages_send": "Mac", "device_send_sms": "iPhone", "device_make_call": "iPhone",
        "send_email": "email"}
# The iPhone's server-only skill: shows / closes the voice card, and names a contact for a chat card.
_CARD_SKILL = "confirm_card"


@dataclass
class Item:
    """One call or message, as the card shows it and as his yes runs it."""
    kind: str                    # call | text | email | message
    tool: str
    to: str
    text: str = ""
    subject: str = ""
    via: str = ""
    run: Optional[Callable[[], Any]] = field(default=None, repr=False, compare=False)

    def card(self) -> dict:
        return {"kind": self.kind, "to": self.to, "text": self.text, "subject": self.subject, "via": self.via}

    def label(self) -> str:
        what = {"call": "the call to", "text": "the text to", "email": "the email to",
                "message": "the message to"}[self.kind]
        said = f" (“{self.text[:120]}”)" if self.text else ""
        return f"{what} {self.to}{said}"


@dataclass
class _Pending:
    items: list[Item]
    seq: int                     # the turn that asked
    at: float
    card_id: str
    device: Optional[str]
    server_asked: bool = False   # the reply didn't ask, so the voice bridge asked for it


@dataclass
class _Turn:
    seq: int
    text: str
    at: float
    reply: str = ""
    length: int = 0
    note: Optional[str] = None   # what this turn was told (re-sent if the same turn runs again)


_lock = threading.Lock()
_turns: "OrderedDict[str, _Turn]" = OrderedDict()   # by chat (the session id)
# By chat id, and by the turn's task id when that differs (a chat whose session id changes
# mid-turn, on compression): both name the same waiting item.
_pending: dict[str, _Pending] = {}
_clock: Callable[[], float] = time.monotonic
# One worker: a card's close never overtakes its show.
_cards = ThreadPoolExecutor(max_workers=1, thread_name_prefix="confirm-card")


# ── what counts ─────────────────────────────────────────────────────────────

def _own_addresses() -> set[str]:
    own = os.getenv("EMAIL_ADDRESS", "").strip().lower()
    return {own} if own else set()


def _from_url(url: str) -> Optional[Item]:
    """A link that places a call or starts a message: tel:, facetime:, sms:, mailto:, WhatsApp."""
    raw = str(url or "").strip()
    scheme = raw.split(":", 1)[0].lower()
    rest = raw[len(scheme) + 1:] if ":" in raw else ""
    target = unquote(re.split(r"[?&]", rest.lstrip("/"), maxsplit=1)[0])
    query = parse_qs(urlsplit(raw.replace("&", "?", 1) if "?" not in raw else raw).query)

    def q(name: str) -> str:
        return (query.get(name) or [""])[0]

    if scheme in ("tel", "telprompt"):
        return Item("call", "device_open_url", target, via="iPhone")
    if scheme in ("facetime", "facetime-audio"):
        return Item("call", "device_open_url", target, via="FaceTime")
    if scheme in ("sms", "imessage"):
        return Item("text", "device_open_url", target, text=q("body"), via="iPhone")
    if scheme == "mailto":
        return Item("email", "device_open_url", target, text=q("body"), subject=q("subject"), via="iPhone")
    host = urlsplit(raw).netloc.lower()
    if scheme == "whatsapp" and urlsplit(raw).netloc.lower() == "send" or host == "api.whatsapp.com":
        return Item("message", "device_open_url", q("phone"), text=q("text"), via="WhatsApp")
    if host == "wa.me":
        return Item("message", "device_open_url", urlsplit(raw).path.strip("/"), text=q("text"), via="WhatsApp")
    return None


def classify(tool: str, args: Any) -> Optional[Item]:
    """The call or message to someone else this tool call would make, or None."""
    a = args if isinstance(args, dict) else {}

    def s(*names: str) -> str:
        return next((str(a[n]).strip() for n in names if a.get(n)), "")

    if tool == "device_make_call":
        return Item("call", tool, s("number", "to"), via=_VIA[tool])
    if tool in ("device_send_sms", "device_messages_send"):
        return Item("text", tool, s("number", "to"), text=s("message", "text", "body"), via=_VIA[tool])
    if tool == "device_open_url":
        return _from_url(s("url"))
    if tool == "device_phone_control":
        if s("action") != "send_message":
            return None
        return Item("text", tool, s("to", "recipient"), text=s("message", "body", "value"), via="iPhone")
    if tool == "send_email":
        to = s("to")
        if to.lower() in _own_addresses():
            return None
        return Item("email", tool, to, text=s("body"), subject=s("subject"), via=_VIA[tool])
    if tool == "send_message":
        target = s("target")
        if (a.get("action") or "send") != "send" or ":" not in target:
            return None   # listing targets, or his own home channel
        return Item("message", tool, target, text=s("message"), via=target.split(":", 1)[0])
    return None


# ── where he is ─────────────────────────────────────────────────────────────

def _voice_turn(chat: str) -> bool:
    try:
        from api import turn_origin
        return turn_origin.is_voice_session(chat)
    except Exception:
        return False


def _phone_for(chat: str) -> Optional[str]:
    """His iPhone when this turn came from it (phone voice or CarPlay): it shows the card."""
    try:
        from api import turn_origin
        if turn_origin.kind_for_session(chat) == "mobile-ios":
            return turn_origin.device_for_session(chat)
    except Exception:
        pass
    return None


def _unattended(task_id: str) -> bool:
    if "~" in task_id or task_id.startswith(_UNATTENDED_PREFIXES):
        return True
    try:
        from tools.approval import _unattended_run
        return bool(_unattended_run.get())
    except Exception:
        return False


def _send_card(device: str, payload: dict) -> None:
    def go() -> None:
        try:
            from api import device_bridge
            device_bridge.invoke_skill(device, _CARD_SKILL, payload, timeout=10)
        except Exception:
            logger.info("confirm card %s not delivered to %s", payload.get("action"), device, exc_info=True)

    _cards.submit(go)


def _show(pending: _Pending) -> None:
    if pending.device:
        _send_card(pending.device, {"action": "show", "id": pending.card_id,
                                    "items": [i.card() for i in pending.items],
                                    "expires_in": int(ANSWER_WITHIN)})


def _close(pending: _Pending, outcome: str) -> None:
    if pending.device:
        _send_card(pending.device, {"action": "close", "id": pending.card_id, "outcome": outcome})


# ── the ask ─────────────────────────────────────────────────────────────────

def _ask_text(item: Item) -> str:
    if item.kind == "call":
        return ("NOT CALLED YET — he confirms first. Reply with only this question, with the person's name: "
                "“Do you want me to call <name>, sir?” The server reads his answer; don't call this tool "
                "again for it.")
    what = {"text": "text", "email": "email", "message": "message"}[item.kind]
    said = f" “{item.text}”" if item.text else ""
    return (f"NOT SENT YET — he confirms first. Reply with only this question, with the person's name: "
            f"“Should I {what} <name>{said}, sir?” Never say it is sent or sending. The server reads his "
            "answer; if he changes something, call this tool again with the change.")


def gate(tool: str, args: Any, *, task_id: Any = None, session_id: Any = None,
         run: Callable[[], Any]) -> Optional[str]:
    """None: go ahead. Otherwise the tool's result, nothing sent: noted for his answer (a voice turn),
    or a chat card he cancelled or left."""
    item = classify(tool, args)
    if item is None:
        return None
    tid = str(task_id or "")
    chat = str(session_id or tid)
    keys = [k for k in dict.fromkeys((chat, tid)) if k]
    if not keys or _unattended(tid):
        return None
    if not any(_voice_turn(k) for k in keys):
        return _ask_on_card(item, keys)
    item.run = run
    now = _clock()
    replaced: Optional[_Pending] = None
    with _lock:
        turn = next((_turns[k] for k in keys if k in _turns), None)
        seq = turn.seq if turn else 0
        pending = next((_pending[k] for k in keys if k in _pending), None)
        if pending is None or pending.seq != seq:
            replaced = pending
            pending = _Pending([], seq, now, uuid.uuid4().hex[:12], next(filter(None, map(_phone_for, keys)), None))
        for k in keys:
            _pending[k] = pending
        # A new draft to the same person replaces the old one (a re-run turn, or the model
        # fixing its own draft) — one yes never sends both.
        pending.items = [i for i in pending.items if (i.tool, i.to) != (item.tool, item.to)] + [item]
        pending.at = now
    if replaced is not None:
        _close(replaced, "cancelled")
    _show(pending)
    logger.info("asked before %s (%s)", item.label(), tool)
    return json.dumps({"status": "awaiting_confirmation", "needs_confirmation": True, "sent": False,
                       "ask": _ask_text(item)}, ensure_ascii=False)


# ── a typed chat turn: the card in the chat, Send or Cancel ─────────────────

_VERB = {"call": "Call", "text": "Text", "email": "Email", "message": "Message"}
_CARD_QUESTION = {"call": "Place this call?", "text": "Send this text?", "email": "Send this email?",
                  "message": "Send this message?"}
CONTACT_WAIT = 2.5  # seconds his iPhone gets to name the person on the card


def _chat_listening(keys: list[str]) -> Optional[str]:
    """The session whose chat is streaming this turn (so it can show the card), or None."""
    try:
        from tools import approval
    except Exception:
        return None
    candidates = [approval.get_current_session_key(""), *keys]
    return next((k for k in candidates if k and approval.has_gateway_listener(k)), None)


def _contact(to: str) -> dict:
    """The person's full name and photo from his iPhone's contacts, as the voice card shows them
    ({} when it doesn't know them, isn't reachable, or takes too long)."""
    if not to or ":" in to:          # a channel target (telegram:…), not a person in his contacts
        return {}
    try:
        from api import device_bridge
        device = device_bridge.device_offering(_CARD_SKILL)
        if not device:
            return {}
        out = device_bridge.invoke_skill(device, _CARD_SKILL, {"action": "lookup", "id": "lookup", "to": to},
                                         timeout=CONTACT_WAIT)
    except Exception:
        logger.info("no contact for the card", exc_info=True)
        return {}
    found = out.get("result") if isinstance(out, dict) and out.get("ok") else None
    name = str(found.get("name") or "").strip() if isinstance(found, dict) else ""
    if not name:
        return {}
    photo = str(found.get("photo") or "")
    return {"name": name, "photo": f"data:image/jpeg;base64,{photo}" if photo else ""}


def _ask_on_card(item: Item, keys: list[str]) -> Optional[str]:
    """A typed turn: the chat shows the card (photo, name, message, Send / Cancel) and the turn waits
    for it. None: he tapped Send, go ahead. Otherwise the tool's result: nothing was sent."""
    session = _chat_listening(keys)
    if session is None:
        return None      # no chat on screen to ask (a messaging platform, a script): sends as before
    who = _contact(item.to)
    said = f": “{item.text[:200]}”" if item.text else ""
    data = {"kind": "send", "approval_id": uuid.uuid4().hex,
            "command": f"{_VERB[item.kind]} {who.get('name') or item.to}{said}",
            "description": _CARD_QUESTION[item.kind],
            "pattern_key": "send_confirm", "pattern_keys": ["send_confirm"],
            "send": {**item.card(), "name": who.get("name", ""), "photo": who.get("photo", "")}}
    from tools import approval
    choice = approval.ask_gateway(session, data, timeout=ANSWER_WITHIN)
    logger.info("card for %s: %s", item.label(), choice)
    if choice in ("once", "session", "always"):
        return None
    done = "called" if item.kind == "call" else "sent"
    if choice == "deny":
        note = (f"He tapped Cancel on the card: nothing was {done}. Say so in a few words; don't try again "
                "unless he asks (he may tell you what to change).")
    elif choice == "timeout":
        note = f"He didn't answer the card within {int(ANSWER_WITHIN // 60)} minutes: nothing was {done}. Tell him."
    else:
        note = f"The confirmation card couldn't be shown, so nothing was {done}. Tell him."
    return json.dumps({"status": "not_sent", "sent": False, "note": note}, ensure_ascii=False)


_SERVER_QUESTION = {"call": "Shall I place the call, sir?", "text": "Should I send the text, sir?",
                    "email": "Should I send the email, sir?", "message": "Should I send the message, sir?"}


def ask_if_unasked(chat: Any, reply: Any) -> Optional[str]:
    """The voice bridge, as a turn's reply ends: when this turn noted a call or message and the
    reply didn't ask about it (a fast model said "Sending that to Shabd now."), the question to
    speak after it — and his answer to it counts. None when there is nothing to ask."""
    key = str(chat or "")
    with _lock:
        turn, pending = _turns.get(key), _pending.get(key)
        if pending is None or turn is None or pending.seq != turn.seq or was_asked(reply, pending.items):
            return None
        pending.server_asked = True
        items = list(pending.items)
    if len(items) > 1:
        return "Should I send them all, sir?"
    return _SERVER_QUESTION[items[0].kind]


# ── his answer ──────────────────────────────────────────────────────────────

def was_asked(reply: Any, items: list[Item]) -> bool:
    asked = " ".join(_QUESTION.findall(text_of(reply)))
    return bool(asked) and all(_ASKED[i.kind].search(asked) for i in items)


def _outcome(result: Any) -> tuple[bool, str]:
    data = result
    if isinstance(result, str):
        try:
            data = json.loads(result)
        except ValueError:
            return True, ""
    if not isinstance(data, dict):
        return True, ""
    inner = data.get("result") if isinstance(data.get("result"), dict) else {}
    error = data.get("error") or inner.get("error")
    ok = not error and all(data.get(k, True) is not False for k in ("ok", "success", "sent"))
    return ok, str(error or "")


def _run(items: list[Item]) -> tuple[str, list[str]]:
    lines, failed = [], False
    for item in items:
        try:
            ok, error = _outcome(item.run() if item.run else {"error": "nothing to run"})
        except Exception as exc:     # never let a send break his turn
            ok, error = False, str(exc)
        failed |= not ok
        done = {"call": "placed", "text": "sent", "email": "sent", "message": "sent"}[item.kind]
        lines.append(f"{item.label()}: {done}" if ok else f"{item.label()}: failed — {error[:200]}")
    return ("failed" if failed else "sent"), lines


def _last_reply(history: Any) -> str:
    for m in reversed(history if isinstance(history, list) else []):
        if isinstance(m, dict) and m.get("role") == "assistant" and m.get("content"):
            return text_of(m.get("content")).strip()
    return ""


def on_turn(task_id: Any, session_id: Any, user_message: Any, history: Any = None) -> Optional[str]:
    """Record his turn; when it answers Jarvis's question, send or drop what was asked. Returns a note
    for this turn's model call, or None."""
    tid = str(task_id or session_id or "")
    if not tid or _unattended(tid):
        return None
    chat = str(session_id or tid)
    words = text_of(user_message).strip()
    reply = _last_reply(history)
    length = len(history) if isinstance(history, list) else 0
    now = _clock()
    with _lock:
        prev = _turns.get(chat)
        if (prev is not None and words == prev.text and reply == prev.reply and length == prev.length
                and now - prev.at < ANSWER_WITHIN):
            return prev.note     # the same turn again (a failed turn re-runs): not a new answer
        turn = _Turn((prev.seq if prev else 0) + 1, words, now, reply, length)
        _turns[chat] = turn
        _turns.move_to_end(chat)
        while len(_turns) > _MAX_CHATS:
            old, _ = _turns.popitem(last=False)
            _pending.pop(old, None)   # (an alias key, if any, goes with its own chat)
        pending = _pending.get(chat) or _pending.get(tid)
        if pending is not None:
            for k in [k for k, p in _pending.items() if p is pending]:
                del _pending[k]
    if pending is None:
        return None
    asked = "; ".join(i.label() for i in pending.items)
    question = " ".join(_QUESTION.findall(reply))
    said = own_words(words)
    # After the yes: words for what was asked, and his reply's own ("Yeah, send it to Shabd").
    extra = frozenset().union(*(_SAYS[i.kind] for i in pending.items),
                              re.findall(r"[a-z']+", reply.lower().replace("’", "'")),
                              ("the", "text", "email", "message", "call", "all", "them"))
    outcome = "cancelled"
    if now - pending.at > ANSWER_WITHIN:
        note = (f"[Not sent: {asked} went unanswered for over 2 minutes, so it was dropped. If he still "
                "wants it, call the tool again so he can confirm.]")
    elif not (pending.server_asked or was_asked(reply, pending.items)):
        note = (f"[Not sent: {asked} was never put to him in your last reply, so it was dropped. If he "
                "wants it, call the tool again and ask him.]")
    elif is_plain_yes(said, extra, echo=question):
        outcome, lines = _run(pending.items)
        note = (f"[He said yes, so the server already did it: {'; '.join(lines)}. Tell him how it went in a "
                "few words (“Sent, sir.” / “Calling him now.”). Don't call the tool again for it.]")
    elif is_plain_no(said):
        note = f"[He said no: nothing was sent ({asked}). Say you won't, in a few words.]"
    else:
        note = (f"[Not sent: his reply isn't a plain yes to {asked}, so that draft was dropped. If he changed "
                "something (the words, the number, the person), call the tool again with the change — it asks "
                "him again. Otherwise answer what he said.]")
    _close(pending, outcome)
    logger.info("answer to %s: %s", asked, outcome)
    with _lock:
        turn.note = note
    return note


def reset_for_tests() -> None:
    with _lock:
        _turns.clear()
        _pending.clear()
