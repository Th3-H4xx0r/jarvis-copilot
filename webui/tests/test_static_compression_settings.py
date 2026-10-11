"""The web wires the auto-compact settings to /api/compression/config.

The behaviour is exercised in a browser; these pin the contract the shipped
static files must keep, so a refactor that drops the block fails here instead
of silently on the phone's Server-settings page.
"""
import pathlib

_STATIC = pathlib.Path(__file__).resolve().parent.parent / "static"


def _read(name):
    return (_STATIC / name).read_text(encoding="utf-8")


def test_settings_page_has_the_compaction_block():
    html = _read("index.html")
    assert 'id="compactionSettings"' in html and 'id="compactionSettingsBody"' in html


def test_settings_js_loads_and_saves_through_the_endpoint():
    js = _read("panels.js")
    assert "api/compression/config" in js
    assert "loadCompactionSettings()" in js
    # Saves send the settings the API validates, and the current model for the readout.
    for field in ("threshold_percent", "max_context_tokens", "enabled"):
        assert field in js, field
    assert "S.session.model_provider" in js or "model_provider" in js
