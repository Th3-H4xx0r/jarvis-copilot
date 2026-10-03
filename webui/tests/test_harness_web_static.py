"""Agent harnesses in the web UI: the header chip, its sheet and the per-turn
harness id (plan Task 15). Static checks over the shipped files."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "static"


def _read(name):
    return (ROOT / name).read_text(encoding="utf-8")


def test_harness_script_loaded_and_precached():
    assert "static/harness.js" in _read("index.html")
    assert "harness.js" in _read("sw.js")


def test_turns_carry_harness_id():
    messages = _read("messages.js")
    i = messages.index("const _startPayload={")
    assert "harness_id" in messages[i:i + 800]
    voice = _read("voice.js")
    i = voice.index("type: 'begin_turn'")
    assert "harness_id" in voice[i - 400:i + 600]


def test_chip_markup_present():
    html = _read("index.html")
    assert 'id="harnessChipChat"' in html
    assert 'id="harnessChipVoice"' in html
    assert 'id="harnessSheet"' in html


def test_chat_chip_replaces_visible_model_chip_but_keeps_the_picker():
    html = _read("index.html")
    wrap = html.index('class="composer-model-wrap"')
    chip = html.index('id="harnessChipChat"')
    model_chip = html.index('id="composerModelChip"')
    # The harness chip sits where the model chip was; the model chip and the
    # hidden select stay in the DOM so "Single model…" can open the old list.
    assert wrap < chip < model_chip
    assert "hidden" in html[model_chip - 120:model_chip + 200]
    assert 'id="modelSelect"' in html and 'id="composerModelDropdown"' in html
    assert ".composer-model-chip[hidden]" in _read("style.css")


def test_phone_overflow_panel_reaches_the_harness_sheet():
    html = _read("index.html")
    start = html.index('id="composerMobileConfigPanel"')
    end = html.index('<div class="profile-dropdown"', start)
    panel = html[start:end]
    assert 'id="composerMobileHarnessAction"' in panel
    assert "Harness.openSheet('chat')" in panel


def test_model_chip_sync_rerenders_the_harness_chip():
    ui = _read("ui.js")
    start = ui.index("function syncModelChip(){")
    end = ui.index("function _positionModelDropdown(){", start)
    assert "Harness.render" in ui[start:end]


def test_sheet_escapes_server_text():
    js = _read("harness.js")
    assert "function esc(" in js
    assert "esc(h.name" in js and "esc(h.id)" in js


def test_chat_turn_sends_the_chats_own_harness_not_the_default():
    from pathlib import Path
    static = Path(__file__).resolve().parents[1] / "static"
    msgs = (static / "messages.js").read_text()
    harness = (static / "harness.js").read_text()
    assert "Harness.turnHarnessFor('chat')" in msgs
    assert "turnHarnessFor" in harness
