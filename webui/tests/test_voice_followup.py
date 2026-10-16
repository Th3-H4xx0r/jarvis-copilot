"""A voice turn that handed its work to the bigger model says so on its end_turn.

The fast lane answers "On it" and ends the turn; the real answer arrives later on
the same socket as ``escalation_result``. A client that closes after one answer
(the CarPlay Talk widget) would drop it — so the end of such a turn carries
``followup: true`` while a hand-off for the session is still running.
"""
from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from agent import escalation  # noqa: E402
from api import voice  # noqa: E402


def setup_function():
    escalation.reset_for_tests()


def teardown_function():
    escalation.reset_for_tests()


def test_a_running_hand_off_marks_the_end_of_the_turn():
    release = threading.Event()
    escalation.start_escalation(session_id="s1", reason="r", summary="s",
                                runner=lambda job: release.wait(5) and "done")
    try:
        assert json.loads(voice._end_turn_frame({"session_id": "s1"})) == {
            "type": "end_turn", "followup": True}
    finally:
        release.set()


def test_a_plain_turn_has_no_followup():
    assert json.loads(voice._end_turn_frame({"session_id": "s1"})) == {"type": "end_turn"}
    assert json.loads(voice._end_turn_frame({})) == {"type": "end_turn"}


def test_another_sessions_hand_off_does_not_count():
    release = threading.Event()
    escalation.start_escalation(session_id="other", reason="r", summary="s",
                                runner=lambda job: release.wait(5) and "done")
    try:
        assert "followup" not in json.loads(voice._end_turn_frame({"session_id": "s1"}))
    finally:
        release.set()
