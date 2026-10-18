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


def _failing(monkeypatch, stderr: str):
    import subprocess as sp

    def run(args, **kw):
        raise sp.CalledProcessError(1, args, output="", stderr=stderr)

    monkeypatch.setattr(mac.subprocess, "run", run)


def test_a_refused_permission_says_how_to_allow_it(monkeypatch):
    # 2026-10-18 06:38: two sends failed with only "returned non-zero exit status 1".
    _failing(monkeypatch, "execution error: Not authorized to send Apple events to Messages. (-1743)")
    with pytest.raises(RuntimeError) as err:
        mac.messages_send("2096277732", "hello")
    assert "Automation" in str(err.value) and "Messages" in str(err.value)


def test_any_other_failure_carries_what_messages_said(monkeypatch):
    _failing(monkeypatch, "execution error: Messages got an error: Can't get participant. (-1728)")
    with pytest.raises(RuntimeError) as err:
        mac.messages_send("2096277732", "hello")
    assert "-1728" in str(err.value)


def test_no_variable_is_named_like_a_messages_term():
    # 2026-10-18 06:50: "Messages got an error: Can't get handle." — inside
    # `tell application "Messages"`, `handle` is Messages' own property, not the
    # script's variable; every send read the app's handle instead of the number.
    import re

    names = set(re.findall(r"\bset (\w+) to\b", mac._SEND_MESSAGE_SCRIPT))
    assert not names & {"handle", "body", "text", "name", "id", "service", "account", "chat", "sms"}, names
