"""Tests for the `messages_send` Mac skill.

From the car, iOS never lets Jarvis send a text silently from the phone (it only
opens a compose screen), so texts go out through the Mac's Messages app, as him.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_skill_messages_send.py -q
"""
from __future__ import annotations

import pytest

from jc_client.skills import _REGISTRY
from jc_client.skills import mac


@pytest.fixture
def osa(monkeypatch):
    calls: list[list[str]] = []

    class Done:
        stdout = "iMessage\n"

    def run(args, **kw):
        calls.append(list(args))
        return Done()

    monkeypatch.setattr(mac.subprocess, "run", run)
    return calls


def test_registered_for_the_server():
    entry = _REGISTRY["messages_send"]
    assert set(entry["input_schema"]["required"]) == {"to", "text"}


def test_the_text_is_an_argument_never_part_of_the_script(osa):
    text = 'hello" & do shell script "say hi'
    result = mac.messages_send("(209) 627-7732", text)
    args = osa[-1]
    assert args[0] == "osascript"
    script = args[args.index("-e") + 1]
    assert text not in script, "the message must not be pasted into AppleScript"
    assert args[-2:] == ["+12096277732", text]
    assert result["ok"] is True
    assert result["to"] == "+12096277732"
    assert result["via"] == "iMessage"


def test_numbers_and_emails_are_kept_as_handles(osa):
    assert mac.messages_send("+44 20 7946 0958", "hi")["to"] == "+442079460958"
    assert mac.messages_send("shabd@example.com", "hi")["to"] == "shabd@example.com"


def test_a_name_is_not_a_handle(osa):
    with pytest.raises(ValueError):
        mac.messages_send("Shabd", "hi")
    with pytest.raises(ValueError):
        mac.messages_send("2096277732", "  ")
    assert osa == []
