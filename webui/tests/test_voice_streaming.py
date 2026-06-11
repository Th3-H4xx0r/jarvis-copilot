"""Tests for the voice streaming/latency + mobile-outage fixes (2026-06-11).

Covers the pure, agent-independent logic:
  * the adaptive first-segment gate (`_take_complete_sentences` min_len), which
    makes the opening clause/ack flush near-instantly while later segments
    batch; and
  * the wiring invariants for the dedicated "Voice" session
    (`/api/voice/session` route + `_VOICE_SOURCE_TAG`).

The end-to-end bridge (model resolution, TTS pipeline, never-silent failures)
needs the JarvisCopilot agent and is exercised by the agent-dependent suite.
"""
import pathlib
import sys

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from api import voice  # noqa: E402
from api.voice import _take_complete_sentences, _VOICE_SOURCE_TAG  # noqa: E402


def test_first_segment_flushes_a_short_sentence_when_min_len_zero():
    # The FIRST segment of a turn uses min_len=0 so the opening sentence/ack is
    # spoken within ~1s — even a tiny "On it." must flush immediately.
    emit, remainder = _take_complete_sentences("On it.", min_len=0)
    assert emit == "On it."
    assert remainder == ""


def test_short_sentence_is_held_at_default_gate():
    # Later segments use the default 110-char gate, so a short fragment is held
    # (buffered) to avoid many tiny TTS calls mid-answer.
    emit, remainder = _take_complete_sentences("On it.")  # default min_len=110
    assert emit is None
    assert remainder == "On it."


def test_first_segment_emits_only_up_to_last_complete_sentence():
    buf = "Good morning. Here is the rest that is still strea"
    emit, remainder = _take_complete_sentences(buf, min_len=0)
    assert emit == "Good morning."
    assert remainder.lstrip() == "Here is the rest that is still strea"


def test_no_terminator_holds_even_with_min_len_zero():
    # min_len=0 still requires a sentence terminator before flushing.
    emit, remainder = _take_complete_sentences("a partial clause with no end yet", min_len=0)
    assert emit is None
    assert remainder == "a partial clause with no end yet"


def test_voice_session_route_is_wired():
    # The dedicated Voice-session endpoint must be routed in handle_voice_get.
    import types
    seen = {}

    class _FakeHandler:  # minimal duck — _voice_session only needs j(handler, ...)
        def send_response(self, *a, **k):
            seen["status"] = a[0] if a else None

        def send_header(self, *a, **k):
            pass

        def end_headers(self):
            pass

        class _W:
            def write(self, *a, **k):
                pass

        wfile = _W()

    # We don't drive the full store here (that needs the agent/session disk
    # layout); we only assert the path is claimed by the voice GET dispatcher.
    parsed = types.SimpleNamespace(path="/api/voice/session")
    # Monkeypatch the handler to avoid touching the real session store.
    orig = voice.get_or_create_voice_session
    voice.get_or_create_voice_session = lambda: types.SimpleNamespace(
        session_id="voice123", title="Voice"
    )
    try:
        claimed = voice.handle_voice_get(_FakeHandler(), parsed)
    finally:
        voice.get_or_create_voice_session = orig
    assert claimed is True


def test_voice_source_tag_constant():
    assert _VOICE_SOURCE_TAG == "voice"


# --- clarify handling in the shared stream-consume loop -----------------------

import queue as _queue  # noqa: E402


class _FakeSub:
    """Minimal subscriber: returns queued (type, data) events, then Empty."""

    def __init__(self, events):
        self._events = list(events)

    def get(self, timeout=None):
        if self._events:
            return self._events.pop(0)
        raise _queue.Empty


class _FakeChannel:
    def __init__(self):
        self.unsubscribed = False

    def unsubscribe(self, sub):
        self.unsubscribed = True


def test_consume_stream_yields_clarify_then_stops_and_unsubscribes():
    from api.voice import _consume_agent_stream

    events = [
        ("token", {"text": "On it. "}),  # min_len=0 first segment → flush "On it."
        ("clarify", {"question": "Who should I email?",
                     "choices_offered": ["a@x.com", "b@y.com", "Other"]}),
        ("token", {"text": "must not be reached"}),
    ]
    ch = _FakeChannel()
    segs = list(_consume_agent_stream(ch, _FakeSub(events), "sid1"))

    kinds = [s["kind"] for s in segs]
    assert kinds == ["text", "clarify"]  # stops AT the clarify, drops trailing token
    assert segs[0]["text"] == "On it."
    assert segs[-1]["question"] == "Who should I email?"
    assert segs[-1]["choices"] == ["a@x.com", "b@y.com", "Other"]
    assert ch.unsubscribed  # always unsubscribes on exit


def test_consume_stream_done_terminates():
    from api.voice import _consume_agent_stream

    events = [("token", {"text": "Hello there."}), ("done", {})]
    ch = _FakeChannel()
    segs = list(_consume_agent_stream(ch, _FakeSub(events), "sid"))
    assert [s["kind"] for s in segs] == ["text"]
    assert segs[0]["text"] == "Hello there."
    assert ch.unsubscribed


def test_format_clarify_speech_appends_choices_but_skips_other():
    from api.voice import _format_clarify_speech

    out = _format_clarify_speech("Who?", ["a@x.com", "b@y.com", "Other"])
    assert "Who?" in out and "a@x.com" in out and "b@y.com" in out
    assert "Other" not in out
    # No usable choices → just the question.
    assert _format_clarify_speech("Proceed?", []) == "Proceed?"
