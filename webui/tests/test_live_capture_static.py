"""The Live page can record from this browser, like the phone's Live screen.

The capture pipeline itself is tested in live_capture.test.js; these pin how the
page is wired to it, so a refactor that drops the Record button or loads the
scripts in the wrong order fails here instead of on screen.
"""
import pathlib

_STATIC = pathlib.Path(__file__).resolve().parent.parent / "static"


def _read(name):
    return (_STATIC / name).read_text(encoding="utf-8")


def test_capture_loads_before_the_live_view():
    html = _read("index.html")
    assert "static/live_capture.js" in html
    assert html.index("static/live_capture.js") < html.index("static/live.js")


def test_live_header_offers_record_and_a_mic_picker():
    js = _read("live.js")
    assert 'data-live-capture="record"' in js and 'id="liveMicSelect"' in js
    assert "JcLiveCapture.createCapture" in js and "JcLiveCapture.listMics" in js
    for action in ("pause", "resume", "stop"):
        assert f"'{action}'" in js, action


def test_the_recording_session_opens_in_the_view():
    js = _read("live.js")
    ready = js[js.index("ready: async"):][:400]
    assert "_liveOpenSession(" in ready


def test_recording_shows_on_the_rail_from_any_page():
    assert "live-capturing" in _read("live.js") and "live-capturing" in _read("live.css")


def test_a_voice_opens_onto_everything_it_said_a_page_at_a_time():
    js = _read("live.js")
    assert 'data-voice-open=' in js
    assert "api/live/speaker_lines" in js and "IntersectionObserver" in js
    assert "before=" in js


def test_a_voice_opens_as_a_popup_from_its_card():
    js = _read("live.js")
    assert "live-voice-modal" in js and "Escape" in js
    assert "_liveOpenVoice(card.dataset.speaker)" in js
