"""Web wiring for the one default (2026-10-12): "can you add support for a harness to be used as the
default instead of it being a single model only".

Settings → Default lists harnesses then models (a harness shows the "Model for Single and fallbacks"
row; a model is saved before the default harness goes back to Single); the Harnesses page sets the
Default plus Voice/Chat overrides; the Voice sheet can follow the default."""
import re
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "static"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_settings_default_offers_harnesses_and_the_single_model_row():
    html, panels = _read("index.html"), _read("panels.js")
    assert 'id="settingsSingleModelRow"' in html and 'id="settingsSingleModel"' in html
    assert "'harness:'" in panels and "surface:'default'" in panels


def test_a_model_default_is_saved_before_the_harness_goes_back_to_single():
    panels = _read("panels.js")
    body = panels[panels.index("async function _saveDefaultChoice"):]
    body = body[:body.index("\n}\n")]
    model_branch = body[body.index("}else if(choice){"):]
    assert model_branch.index("/api/default-model") < model_branch.index("harness_id:'single'")


def test_both_save_paths_and_the_dirty_check_use_the_default_choice():
    panels = _read("panels.js")
    assert panels.count("await _saveDefaultChoice(body)") == 2
    assert "_defaultChoiceChanged()" in panels[panels.index("const pwDirty"):panels.index("const pwDirty") + 400]


def test_harness_page_sets_default_and_overrides():
    editor = _read("harness_editor.js")
    assert "assignSelect('default')" in editor and "Same as default" in editor
    assert re.search(r"E\.overrides\s*=", editor)


def test_voice_sheet_can_follow_the_default():
    sheet = _read("harness.js")
    assert "Same as default" in sheet and "overrides" in sheet
