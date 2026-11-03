"""The agent's tools for an integration's own UI: get, set, test."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

import jarvis_registry.store as store
import tools.registry_tools as rt
from jarvis_registry import Registry, ui

SKILL_DIR = Path(__file__).resolve().parents[2] / "skills" / "jarviscopilot" / "integration-ui"

LOAD = (
    "from jarvis_registry import ui_script as u\n"
    "u.reply({'n': u.space().get('n', default=0)})\n"
)
BUMP = (
    "from jarvis_registry import ui_script as u\n"
    "s = u.space()\n"
    "s.put('n', s.get('n', default=0) + 1)\n"
    "u.reply(toast='Bumped')\n"
)
CARD = {"type": "hstack", "children": [
    {"type": "stat", "value": {"$": "n"}},
    {"type": "button", "label": "Bump", "action": "bump"},
]}


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    ui._reset_cache()
    yield r
    r.close()


def call(handler, **args) -> dict:
    return json.loads(handler(args=args))


def test_set_stores_and_loads(reg):
    reg.space("counter", name="Counter")
    out = call(rt._h_ui_set, space="counter", card=CARD,
               scripts={"load": {"code": LOAD}, "bump": {"code": BUMP}},
               prompt="a counter")
    assert out["ok"] is True, out
    assert out["version"] == 1
    assert out["state_preview"] == {"n": 0}
    assert out["load_error"] is None

    got = call(rt._h_ui_get, space="counter")
    assert got["ok"] is True and got["ui"]["prompt"] == "a counter"
    assert got["ui"]["scripts"]["bump"]["code"] == BUMP


def test_set_refuses_an_invalid_ui_with_readable_errors(reg):
    reg.space("counter", name="Counter")
    out = call(rt._h_ui_set, space="counter", card=CARD,
               scripts={"bump": {"code": BUMP}})
    assert out["ok"] is False
    assert any("load" in e for e in out["errors"])
    assert "load" in out["error"]
    assert reg.open("counter").get("ui") is None


def test_test_runs_load_and_actions(reg):
    reg.space("counter", name="Counter")
    call(rt._h_ui_set, space="counter", card=CARD,
         scripts={"load": {"code": LOAD}, "bump": {"code": BUMP}})
    loaded = call(rt._h_ui_test, space="counter")
    assert loaded["ok"] is True and loaded["state"] == {"n": 0}

    bumped = call(rt._h_ui_test, space="counter", action="bump")
    assert bumped["ok"] is True and bumped["state"] == {"n": 1}
    assert bumped["toast"] == "Bumped"


def test_get_for_an_integration_without_a_ui(reg):
    reg.space("counter", name="Counter")
    out = call(rt._h_ui_get, space="counter")
    assert out["ok"] is True and out["ui"] is None


def test_registry_put_refuses_the_ui_key(reg):
    reg.space("counter", name="Counter")
    out = call(rt._h_put, space="counter", key="ui", body={"x": 1})
    assert out["ok"] is False and "integration_ui_set" in out["error"]


def test_ui_is_not_an_integration_id(reg):
    out = call(rt._h_create, name="UI")
    assert out["ok"] is False


def test_the_ui_tools_are_in_the_registry_toolset():
    import toolsets
    from tools.registry import registry as tool_registry

    for name in ("integration_ui_get", "integration_ui_set", "integration_ui_test"):
        entry = tool_registry.get_entry(name)
        assert entry is not None and entry.toolset == "registry"
        assert name in toolsets.TOOLSETS["registry"]["tools"]


# ── the skill that teaches it ────────────────────────────────────────────────
def _examples() -> list[dict]:
    text = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
    text += (SKILL_DIR / "references" / "examples.md").read_text(encoding="utf-8")
    blocks = re.findall(r"```json ui-example\n(.*?)\n```", text, re.S)
    return [json.loads(b) for b in blocks]


def test_the_skill_is_well_formed():
    text = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
    match = re.search(r"^description: (.*)$", text, re.MULTILINE)
    assert match and len(match.group(1)) <= 60
    assert (SKILL_DIR / "references" / "elements.md").exists()


def test_every_skill_example_is_a_valid_ui():
    examples = _examples()
    assert len(examples) >= 3
    for example in examples:
        errors, _ = ui.validate_ui(example)
        assert errors == [], errors


def test_every_node_type_is_documented():
    elements = (SKILL_DIR / "references" / "elements.md").read_text(encoding="utf-8")
    for ntype in ui.NODE_TYPES:
        assert f"`{ntype}`" in elements, f"{ntype} is not in elements.md"


def test_the_skill_examples_run(reg):
    """Each example's load works on an empty space, so a copied one never starts broken."""
    for i, example in enumerate(_examples()):
        space_id = f"example{i}"
        reg.space(space_id, name=f"Example {i}")
        ui.save_ui(space_id, example)
        out = ui.load_state(space_id)
        assert out["error"] is None, (i, out["error"])
