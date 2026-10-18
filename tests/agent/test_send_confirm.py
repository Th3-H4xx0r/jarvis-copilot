"""Calls, texts, emails and messages to other people ask first on a voice turn (agent/send_confirm.py).

Pranav (2026-10-18): a card with the contact's photo, name and message, Jarvis says it, the mic stays
open, and his yes — or the card's Send — does it; no or ✕ drops it; a correction re-drafts it. His
picks: every voice surface (typed chat sends as today); calls, texts, emails, other-app messages.
"""
from __future__ import annotations

import json

import pytest

from agent import send_confirm as sc

CHAT = "sess-voice"
TEXT_ARGS = {"to": "+12096277732", "text": "hello"}


@pytest.fixture
def world(monkeypatch):
    """A voice chat on his iPhone; cards and runs are recorded, never sent."""
    sc.reset_for_tests()
    voice = {CHAT}
    cards: list[tuple[str, dict]] = []
    monkeypatch.setattr(sc, "_voice_turn", lambda chat: chat in voice)
    monkeypatch.setattr(sc, "_phone_for", lambda chat: "iphone-1")
    monkeypatch.setattr(sc, "_send_card", lambda device, payload: cards.append((device, payload)))
    clock = [1000.0]
    monkeypatch.setattr(sc, "_clock", lambda: clock[0])
    yield {"voice": voice, "cards": cards, "clock": clock}
    sc.reset_for_tests()


class _Runs:
    def __init__(self, result='{"ok": true}'):
        self.calls = 0
        self.result = result

    def __call__(self):
        self.calls += 1
        return self.result


def _turn(words, reply="", history_len=0):
    history = [{"role": "user", "content": "x"}] * history_len
    if reply:
        history.append({"role": "assistant", "content": reply})
    return sc.on_turn(CHAT, CHAT, words, history)


def _ask(tool="device_messages_send", args=None, runs=None):
    _turn("text Shabd hello")
    runs = runs or _Runs()
    out = sc.gate(tool, dict(args or TEXT_ARGS), task_id=CHAT, session_id=CHAT, run=runs)
    return out, runs


# ── what counts ─────────────────────────────────────────────────────────────

@pytest.mark.parametrize("tool,args,kind,to", [
    ("device_make_call", {"number": "(209) 627-7732"}, "call", "(209) 627-7732"),
    ("device_send_sms", {"number": "2096277732", "message": "hi"}, "text", "2096277732"),
    ("device_messages_send", {"to": "+12096277732", "text": "hi"}, "text", "+12096277732"),
    ("device_open_url", {"url": "tel:+12096277732"}, "call", "+12096277732"),
    ("device_open_url", {"url": "facetime://shabd@example.com"}, "call", "shabd@example.com"),
    ("device_open_url", {"url": "sms:+12096277732&body=hi%20there"}, "text", "+12096277732"),
    ("device_open_url", {"url": "mailto:shabd@example.com?subject=Hi&body=Yo"}, "email", "shabd@example.com"),
    ("device_open_url", {"url": "whatsapp://send?phone=12096277732&text=hey"}, "message", "12096277732"),
    ("device_open_url", {"url": "https://wa.me/12096277732?text=hey"}, "message", "12096277732"),
    ("send_email", {"to": "shabd@example.com", "subject": "Hi", "body": "Yo"}, "email", "shabd@example.com"),
    ("send_message", {"target": "telegram:@shabd", "message": "yo"}, "message", "telegram:@shabd"),
])
def test_calls_and_messages_to_someone_are_gated(tool, args, kind, to):
    item = sc.classify(tool, args)
    assert item is not None and item.kind == kind and item.to == to


def test_the_message_text_comes_along():
    assert sc.classify("device_open_url", {"url": "sms:+12096277732&body=hi%20there"}).text == "hi there"
    email = sc.classify("send_email", {"to": "a@b.c", "subject": "Hi", "body": "Yo"})
    assert (email.subject, email.text) == ("Hi", "Yo")


@pytest.mark.parametrize("tool,args", [
    ("device_open_url", {"url": "https://maps.apple.com/?daddr=Costco"}),
    ("device_open_url", {"url": "spotify:track:123"}),
    ("send_message", {"action": "list"}),
    ("send_message", {"target": "telegram", "message": "a note to himself"}),  # his own home channel
    ("device_read_contacts", {"query": "Shabd"}),
    ("terminal", {"command": "ls"}),
])
def test_everything_else_goes_straight_through(tool, args):
    assert sc.classify(tool, args) is None


def test_email_to_himself_is_not_gated(monkeypatch):
    monkeypatch.setenv("EMAIL_ADDRESS", "Me@Example.com")
    assert sc.classify("send_email", {"to": "me@example.com", "body": "note"}) is None


# ── the ask ─────────────────────────────────────────────────────────────────

def test_a_voice_turn_asks_instead_of_sending_and_shows_the_card(world):
    out, runs = _ask()
    payload = json.loads(out)
    assert payload["needs_confirmation"] is True and payload["sent"] is False
    assert "hello" in payload["ask"] and "?" in payload["ask"]
    assert runs.calls == 0
    device, card = world["cards"][-1]
    assert device == "iphone-1" and card["action"] == "show"
    assert card["items"] == [{"kind": "text", "to": "+12096277732", "text": "hello", "subject": "", "via": "Mac"}]
    assert card["expires_in"] == int(sc.ANSWER_WITHIN)


def test_a_typed_turn_sends_at_once(world):
    world["voice"].clear()
    _turn("text Shabd hello")
    assert sc.gate("device_messages_send", dict(TEXT_ARGS), task_id=CHAT, session_id=CHAT, run=_Runs()) is None
    assert world["cards"] == []


@pytest.mark.parametrize("task_id", ["sa-123", "subagent-9", "bg_77", f"{CHAT}~node", "live-1"])
def test_runs_with_nobody_to_answer_are_left_alone(world, task_id):
    assert sc.gate("device_make_call", {"number": "1"}, task_id=task_id, session_id=CHAT, run=_Runs()) is None


def test_no_phone_no_card_but_still_asks(world, monkeypatch):
    monkeypatch.setattr(sc, "_phone_for", lambda chat: None)  # Mac / web / Pod voice
    out, _ = _ask()
    assert json.loads(out)["needs_confirmation"] is True
    assert world["cards"] == []


# ── his answer ──────────────────────────────────────────────────────────────

ASKED = "I'll text Shabd Patel: “hello”. Should I send it, sir?"


def test_his_yes_sends_it_before_the_model_answers(world):
    _, runs = _ask()
    note = _turn("Yes.", reply=ASKED, history_len=2)
    assert runs.calls == 1
    assert "sent" in note.lower() and "don't call" in note.lower()
    assert world["cards"][-1][1] == {"action": "close", "id": world["cards"][0][1]["id"], "outcome": "sent"}


def test_the_card_button_is_his_yes(world):
    _, runs = _ask()
    _turn("Yes.", reply=ASKED, history_len=2)   # what Send says on the voice session
    assert runs.calls == 1


def test_a_yes_naming_the_person_still_counts(world):
    _, runs = _ask()
    _turn("Yeah, send it to Shabd", reply=ASKED, history_len=2)
    assert runs.calls == 1


def test_a_failed_send_is_reported_as_failed(world):
    _, runs = _ask(runs=_Runs('{"ok": false, "error": "Messages couldn\'t send it"}'))
    note = _turn("yes", reply=ASKED, history_len=2)
    assert runs.calls == 1 and "couldn't send it" in note
    assert world["cards"][-1][1]["outcome"] == "failed"


def test_his_no_drops_it(world):
    _, runs = _ask()
    note = _turn("No, don't send it", reply=ASKED, history_len=2)
    assert runs.calls == 0 and "said no" in note
    assert world["cards"][-1][1]["outcome"] == "cancelled"


def test_a_correction_drops_it_and_says_to_draft_again(world):
    _, runs = _ask()
    note = _turn("No, say I'm running late instead", reply=ASKED, history_len=2)
    assert runs.calls == 0
    assert "again with the change" in note
    assert world["cards"][-1][1]["outcome"] == "cancelled"


def test_a_yes_to_some_other_question_never_sends(world):
    _, runs = _ask()
    note = _turn("Yes", reply="Want me to check the weather too?", history_len=2)
    assert runs.calls == 0 and "never put to him" in note


def test_a_late_yes_never_sends(world):
    _, runs = _ask()
    world["clock"][0] += sc.ANSWER_WITHIN + 1
    note = _turn("Yes", reply=ASKED, history_len=2)
    assert runs.calls == 0 and "unanswered" in note


def test_the_same_turn_run_again_does_not_send_twice(world):
    _, runs = _ask()
    first = _turn("Yes", reply=ASKED, history_len=2)
    again = _turn("Yes", reply=ASKED, history_len=2)  # a failed turn re-runs with his message
    assert runs.calls == 1 and again == first


def test_one_yes_covers_everything_asked_that_turn(world):
    _turn("text Shabd and Sarah hello")
    a, b = _Runs(), _Runs()
    sc.gate("device_messages_send", dict(TEXT_ARGS), task_id=CHAT, session_id=CHAT, run=a)
    sc.gate("device_messages_send", {"to": "+15550100000", "text": "hello"}, task_id=CHAT, session_id=CHAT, run=b)
    shown = [c for _, c in world["cards"] if c["action"] == "show"]
    assert len(shown[-1]["items"]) == 2 and shown[-1]["id"] == shown[0]["id"]
    _turn("yes", reply="Should I send both texts, sir?", history_len=2)
    assert (a.calls, b.calls) == (1, 1)


def test_a_call_needs_a_question_about_calling(world):
    _turn("call Shabd")
    runs = _Runs()
    sc.gate("device_make_call", {"number": "2096277732"}, task_id=CHAT, session_id=CHAT, run=runs)
    _turn("Yes, call him", reply="Do you want me to call Shabd Patel, sir?", history_len=2)
    assert runs.calls == 1


# ── wiring ──────────────────────────────────────────────────────────────────

def test_the_dispatcher_asks_on_a_voice_turn(world, monkeypatch):
    import model_tools

    sent = []
    monkeypatch.setattr(model_tools.registry, "dispatch", lambda name, args, **kw: sent.append(name) or "{}")
    _turn("call Shabd")
    out = model_tools.handle_function_call("device_make_call", {"number": "2096277732"},
                                           task_id=CHAT, session_id=CHAT)
    assert json.loads(out)["needs_confirmation"] is True and sent == []
    _turn("yes", reply="Do you want me to call Shabd, sir?", history_len=2)
    assert sent == ["device_make_call"]
