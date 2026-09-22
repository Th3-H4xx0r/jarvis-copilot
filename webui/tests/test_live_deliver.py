"""Outbound delivery: what a device is sent, given what it said it can show.

The rule under test throughout is §13.4's first line — never send a form a
device did not declare. The second rule is that the device which predates the
`out` block (the phone in the user's pocket) must be unaffected by all of it.
"""
from __future__ import annotations

import pytest

from api import live_deliver


def _intent(**over):
    base = {"kind": "monitor", "live_session_id": "s1",
            "text": "The Nile is the longest river in the world.",
            "seq": 4}
    base.update(over)
    return base


def _out(**over):
    base = {"text": True, "speak": False, "haptic": False, "max_chars": 0,
            "locale": "", "audio": [], "legacy": False}
    base.update(over)
    return base


def _kinds(frames):
    return [f["t"] for f in frames]


@pytest.fixture
def bus(monkeypatch):
    """Catch what `deliver()` publishes, without a socket or a database.

    `live_deliver` imports the bus lazily (the protocol layer owns it and a
    watcher must still work when it is absent), so the stub goes where that
    import will find it.
    """
    import sys
    import types

    published: list = []

    class _Bus:
        def publish(self, sid, event, data):
            published.append((event, data))

    module = types.ModuleType("api.live_ws")
    module.LIVE_EVENTS = _Bus()
    monkeypatch.setitem(sys.modules, "api.live_ws", module)
    return published


# ── what a device declares ────────────────────────────────────────────────


def test_a_device_with_no_out_block_keeps_the_behaviour_it_shipped_with():
    """The phone declares `caps.speak` and nothing else. Reading "declared no
    output" as "receives nothing" would have silenced the only device there is.
    """
    out = live_deliver.device_out({"stt": "on_device", "speak": True})
    assert out["text"] is True
    assert out["speak"] is True
    assert out["max_chars"] == 0, "a phone has no line limit"
    assert out["legacy"] is True


def test_a_device_that_declares_an_out_block_gets_exactly_that():
    out = live_deliver.device_out({"speak": True, "out": {"text": True,
                                                          "max_chars": 80}})
    assert out["text"] is True
    assert out["speak"] is False, \
        "an out block is the whole declaration; caps.speak no longer leaks in"
    assert out["max_chars"] == 80


def test_a_device_that_declares_nothing_at_all_receives_nothing():
    out = live_deliver.device_out({"out": {}})
    assert live_deliver.render(_intent(), out) == []


def test_a_codec_list_may_be_written_either_way():
    assert live_deliver.device_out({"out": {"audio": "MP3"}})["audio"] == ["mp3"]
    assert live_deliver.device_out(
        {"out": {"audio": ["mp3", "Opus"]}})["audio"] == ["mp3", "opus"]


# ── fitting a note to a display ───────────────────────────────────────────


def test_a_note_that_fits_is_untouched():
    frames = live_deliver.render(_intent(), _out(max_chars=200))
    assert frames[0]["text"] == _intent()["text"]
    assert "truncated" not in frames[0]


def test_a_note_too_long_for_the_display_is_cut_visibly():
    """Truncation is the server's job and must be visible, never a silent drop
    (§13.4) — the device has to be able to say "more on your phone"."""
    frames = live_deliver.render(_intent(), _out(max_chars=20))
    text = frames[0]["text"]
    assert len(text) <= 20
    assert text.endswith("…")
    assert frames[0]["truncated"] is True
    assert frames[0]["full_chars"] == len(_intent()["text"])


def test_a_cut_lands_on_a_word_boundary_when_there_is_one():
    text, truncated = live_deliver.fit("The Nile is the longest river", 20)
    assert truncated
    assert text == "The Nile is the…"


def test_one_very_long_word_is_still_cut_rather_than_erased():
    """Backing up to a word boundary that is at position 0 would send an
    ellipsis and nothing else."""
    text, truncated = live_deliver.fit("Llanfairpwllgwyngyllgogerych", 10)
    assert truncated
    assert text == "Llanfairp…"


def test_a_display_smaller_than_the_ellipsis_is_not_an_exception():
    assert live_deliver.fit("anything", 1) == ("…", True)


# ── speech ────────────────────────────────────────────────────────────────


def test_text_mode_sends_no_speech_even_to_a_device_that_can_speak():
    frames = live_deliver.render(_intent(), _out(speak=True), reply_mode="text")
    assert _kinds(frames) == ["insight"]


def test_spoken_mode_sends_both_to_a_device_that_declared_both():
    frames = live_deliver.render(_intent(), _out(speak=True),
                                 reply_mode="spoken")
    assert _kinds(frames) == ["insight", "speak"]
    assert frames[1]["text"] == _intent()["text"]


def test_a_speaker_with_no_display_is_spoken_to_only():
    """The pod in §13.3: `out.speak: true, text: false`."""
    frames = live_deliver.render(_intent(), _out(text=False, speak=True),
                                 reply_mode="spoken")
    assert _kinds(frames) == ["speak"]


def test_speech_is_not_trimmed_to_a_display_it_is_not_shown_on():
    """A device with a one-line display and a voice says the whole thing; the
    line is what is short, not the sentence."""
    frames = live_deliver.render(_intent(), _out(speak=True, max_chars=20),
                                 reply_mode="spoken")
    assert frames[0]["text"].endswith("…")
    assert frames[1]["text"] == _intent()["text"]


def test_an_intent_that_refuses_speech_is_not_spoken(bus):
    """A translation is a line of UI attached to an utterance. Reading it aloud
    talks over the conversation it is translating, so the kind decides and the
    setting does not get a vote."""
    live_deliver.deliver("s1", {"kind": "translation", "text": "hola"})
    intent = bus[0][1]
    assert intent["speak"] is False
    assert _kinds(live_deliver.render(intent, _out(speak=True),
                                      reply_mode="spoken")) == ["insight"]


def test_an_intent_that_asks_to_be_spoken_wins_over_the_setting():
    frames = live_deliver.render(_intent(speak=True), _out(speak=True),
                                 reply_mode="text")
    assert "speak" in _kinds(frames)


def test_spoken_mode_on_a_mute_device_falls_back_to_text_and_says_so_once():
    """§13.4: not an error, but not silence either — the setting did nothing
    and the user has to be able to find out why."""
    first = live_deliver.render(_intent(), _out(speak=False),
                                reply_mode="spoken", say_speech_missing=True)
    again = live_deliver.render(_intent(), _out(speak=False),
                                reply_mode="spoken", say_speech_missing=False)
    assert first[0]["spoken_unavailable"] is True
    assert "spoken_unavailable" not in again[0]


# ── urgency ───────────────────────────────────────────────────────────────


def test_a_watch_buzzes_only_for_something_urgent():
    urgent = live_deliver.render(_intent(urgency="urgent"), _out(haptic=True))
    calm = live_deliver.render(_intent(urgency="normal"), _out(haptic=True))
    assert urgent[0]["haptic"] is True
    assert "haptic" not in calm[0]


def test_a_device_that_cannot_buzz_is_never_told_to():
    frames = live_deliver.render(_intent(urgency="urgent"), _out(haptic=False))
    assert "haptic" not in frames[0]


# ── synthesised audio ─────────────────────────────────────────────────────


def test_a_device_that_speaks_text_itself_is_not_sent_megabytes(monkeypatch):
    """A phone has a synthesiser. Sending it audio would cost a round trip to
    replace something it does better."""
    called = []
    monkeypatch.setattr(live_deliver, "_server_audio",
                        lambda text, out: called.append(out) or {})
    live_deliver.render(_intent(), _out(speak=True), reply_mode="spoken")
    assert called and called[0]["audio"] == []


def test_a_device_with_no_synthesiser_is_sent_audio_it_can_play(monkeypatch):
    import api.voice as voice
    monkeypatch.setattr(voice, "_tts_to_base64", lambda text: "QUJD")
    frames = live_deliver.render(_intent(), _out(speak=True, audio=["mp3"]),
                                 reply_mode="spoken")
    speech = frames[-1]
    assert speech["audio_b64"] == "QUJD"
    assert speech["mime"] == "audio/mpeg"


def test_audio_a_device_cannot_decode_is_never_sent(monkeypatch):
    """It gets the text to speak instead — a form it declared — rather than
    bytes it would silently drop."""
    import api.voice as voice
    monkeypatch.setattr(voice, "_tts_to_base64",
                        lambda text: pytest.fail("should not synthesise"))
    frames = live_deliver.render(_intent(), _out(speak=True, audio=["opus"]),
                                 reply_mode="spoken")
    assert "audio_b64" not in frames[-1]
    assert frames[-1]["text"] == _intent()["text"]


def test_synthesis_failing_costs_the_audio_not_the_note(monkeypatch):
    import api.voice as voice

    def _boom(text):
        raise RuntimeError("no credit")

    monkeypatch.setattr(voice, "_tts_to_base64", _boom)
    frames = live_deliver.render(_intent(), _out(speak=True, audio=["mp3"]),
                                 reply_mode="spoken")
    assert "audio_b64" not in frames[-1]
    assert frames[-1]["text"] == _intent()["text"]


# ── the intent itself ─────────────────────────────────────────────────────


def test_a_fact_check_is_urgent_and_a_monitor_note_is_not(bus):
    """The user tapped a button and is waiting for this one."""
    live_deliver.deliver("s1", {"kind": "fact_check", "text": "no"})
    live_deliver.deliver("s1", {"kind": "monitor", "text": "hm"})

    assert bus[0][1]["urgency"] == "urgent"
    assert bus[1][1]["urgency"] == "normal"
    assert [event for event, _ in bus] == ["insight", "insight"], \
        "it still goes out as an insight, which is what records it"


def test_a_watcher_note_reaches_delivery_with_the_session_it_belongs_to(bus):
    intent = live_deliver.deliver("s7", {"kind": "monitor", "text": "hm"})
    assert intent["live_session_id"] == "s7"
    assert bus[0][1]["live_session_id"] == "s7"


def test_an_empty_note_is_not_delivered_in_any_form():
    assert live_deliver.render(_intent(text="   "), _out(speak=True),
                               reply_mode="spoken") == []
