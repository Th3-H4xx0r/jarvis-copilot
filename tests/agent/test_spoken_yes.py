"""The plain yes / plain no a server-checked confirmation accepts (agent/spoken_yes.py).

Car commands (plugins/toyota/confirm.py) and calls/texts (agent/send_confirm.py) both run only on his
own clear answer, read by the server — never on the model's say-so.
"""
from __future__ import annotations

import pytest

from agent.spoken_yes import is_plain_no, is_plain_yes, own_words


@pytest.mark.parametrize("said", [
    "Yes.", "Yeah, send it", "Yep", "Sure.", "Go ahead", "Okay, do it", "Yes please, Jarvis",
    "Hey Jarvis, yes", "Yes, send it now", "Absolutely, sir",
])
def test_a_plain_yes(said):
    assert is_plain_yes(said)


@pytest.mark.parametrize("said", [
    "No", "Yes, but say hi instead", "Wait", "Yeah, I was thinking about it", "What did it say?",
    "Sure, if he's free", "", "Okay, change it to Sarah",
])
def test_not_a_plain_yes(said):
    assert not is_plain_yes(said)


def test_words_naming_what_was_asked_may_follow_the_yes():
    assert not is_plain_yes("Yes, call him")
    assert is_plain_yes("Yes, call him", extra={"call", "him"})


def test_the_echo_of_the_question_is_not_his_answer():
    assert is_plain_yes("send it? Yes", echo="Should I send it?")


@pytest.mark.parametrize("said", ["No.", "Nope", "No, don't send it", "Cancel", "Never mind", "No thanks",
                                  "Don't call him"])
def test_a_plain_no(said):
    assert is_plain_no(said)


@pytest.mark.parametrize("said", ["No, say I'm running late instead", "No, text Sarah", "Yes", "Nobody"])
def test_a_no_with_a_change_is_not_a_plain_no(said):
    assert not is_plain_no(said)


def test_his_own_words_come_out_of_the_wrappers():
    assert own_words("[Workspace::v1: /root/workspace] Yes.") == "Yes."
    assert own_words("[Workspace::v1: /root/workspace]\nYes.") == "Yes."
    assert own_words('[The user sent a voice message~ Here\'s what they said: "yes go"]') == "yes go"
    assert own_words('[Replying to: "Send it?"]\n\nYes') == "Yes"
    assert own_words([{"type": "text", "text": "Yes"}]) == "Yes"


@pytest.mark.parametrize("said", ["Don't send it", "Wait, don't send it", "No"])
def test_a_doubt_that_echoes_the_question_is_still_doubt(said):
    # The question itself may hold "don't" / "wait" ("Should I text Mom “don't wait up”, sir?"):
    # taking those as the mic's echo of the question turned "Don't send it" into a yes.
    assert not is_plain_yes(said, echo="Should I text Mom “don't wait up”, sir?")
