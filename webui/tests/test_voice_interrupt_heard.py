"""What the user actually heard when they interrupted a spoken reply.

The server generates a reply faster than the client speaks it, so by the time
someone cuts in, the whole reply is usually written — and the model's next turn
would assume they heard all of it. The client now sends the words it had played
(`interrupt{heard}`), and the next voice turn's system directive says so.

Pure unit tests of the control-frame handler and the directive builder: no
agent, no socket I/O.
"""
import pathlib
import sys
import threading

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

import api.voice as voice  # noqa: E402


def _fresh_state():
    return {
        "lock": threading.Lock(),
        "pcm_buf": bytearray(),
        "interrupt": False,
        "clarify_pending": False,
        "sample_rate": 16000,
        "session_id": "",
    }


def _interrupt(state, **fields):
    # The interrupt branch cancels the active chat stream; there is none here.
    voice._handle_control_frame({"type": "interrupt", **fields}, state, None, None)


def test_interrupt_records_what_was_heard():
    state = _fresh_state()
    _interrupt(state, heard="The forecast for today is sunny with")
    assert state["interrupt"] is True
    assert state["heard_before_interrupt"] == "The forecast for today is sunny with"


def test_interrupt_before_any_word_records_that_nothing_was_heard():
    state = _fresh_state()
    _interrupt(state, heard="")
    assert state["heard_before_interrupt"] == ""


def test_an_older_client_without_heard_leaves_no_note():
    state = _fresh_state()
    _interrupt(state)
    assert "heard_before_interrupt" not in state


def test_a_very_long_reply_keeps_the_end_of_what_was_heard():
    state = _fresh_state()
    heard = "word " * 2000
    _interrupt(state, heard=heard)
    kept = state["heard_before_interrupt"]
    assert len(kept) <= voice._HEARD_TEXT_MAX_CHARS
    assert heard.strip().endswith(kept.strip())


def test_the_directive_is_unchanged_without_an_interruption():
    assert voice._voice_turn_directive(None) == voice._VOICE_REPLY_DIRECTIVE


def test_the_directive_quotes_what_was_heard():
    directive = voice._voice_turn_directive("The forecast for today is sunny with")
    assert directive.startswith(voice._VOICE_REPLY_DIRECTIVE)
    assert "interrupted" in directive
    assert "The forecast for today is sunny with" in directive


def test_the_directive_says_when_none_of_the_reply_was_heard():
    directive = voice._voice_turn_directive("")
    assert "interrupted" in directive
    assert "none of it" in directive


def test_the_next_turn_takes_the_note_once():
    state = _fresh_state()
    _interrupt(state, heard="Sure, the first step is")
    assert voice._take_heard_before_interrupt(state) == "Sure, the first step is"
    assert voice._take_heard_before_interrupt(state) is None
