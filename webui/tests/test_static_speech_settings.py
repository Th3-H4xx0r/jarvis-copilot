"""The web wires the speech settings and the server's live words.

The behaviour is exercised in a browser; these pin the contract the shipped
static files must keep with /api/speech/* and the Live `partial` event, so a
refactor that drops one fails here instead of silently on the phone's
Server-settings page.
"""
import pathlib
import re

_STATIC = pathlib.Path(__file__).resolve().parent.parent / "static"


def _read(name):
    return (_STATIC / name).read_text(encoding="utf-8")


def test_settings_page_has_the_speech_block():
    html = _read("index.html")
    assert 'id="speechSettings"' in html and 'id="speechSettingsBody"' in html


def test_settings_js_uses_every_speech_endpoint():
    js = _read("panels.js")
    for path in ("api/speech/config", "api/speech/soniox-key", "api/speech/test"):
        assert path in js, path
    assert "loadSpeechSettings()" in js
    # The key is write-only: nothing in the page may put a saved key back into a field.
    assert not re.search(r"\.value\s*=\s*[^;]*soniox_key", js)


def test_live_view_renders_server_words_and_offers_the_engine():
    js = _read("live.js")
    assert "addEventListener('partial'" in js
    assert "api/speech/config" in js
