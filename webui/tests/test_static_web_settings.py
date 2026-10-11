"""Settings → Web & browser in the web UI: the block exists, loads with the settings
pane, talks to /api/web/config, and offers harnesses as well as models."""
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "static"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_the_block_is_in_the_settings_pane():
    html = _read("index.html")
    assert 'id="webBrowserSettings"' in html and 'id="webBrowserSettingsBody"' in html


def test_it_loads_with_the_pane_and_uses_its_endpoint():
    js = _read("panels.js")
    start = js.index("async function loadSettingsPanel(")
    assert "loadWebBrowserSettings()" in js[start:start + 400]
    body = js[js.index("async function loadWebBrowserSettings("):]
    body = body[:body.index("\nasync function loadSettingsPanel(")]
    assert "/api/web/config" in body and "harness:" in body and "api/harnesses" in body
    assert "stealth_fallback" in body and "engine" in body
