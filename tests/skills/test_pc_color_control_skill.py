"""Tests for skills/smart-home/pc-color-control — its SKILL.md and its contract with the PC Lighting tools."""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "skills" / "smart-home" / "pc-color-control"
SKILL_MD = SKILL_DIR / "SKILL.md"


def _text() -> str:
    return SKILL_MD.read_text(encoding="utf-8")


def _frontmatter(key: str) -> str:
    match = re.search(rf"^{key}: (.*)$", _text(), re.MULTILINE)
    assert match, key
    return match.group(1).strip()


def _tools():
    import tools.pc_lighting_tool  # noqa: F401  (registers the tools)
    from tools.registry import registry
    return registry


def test_description_is_one_short_sentence():
    desc = _frontmatter("description")
    assert len(desc) <= 60 and desc.endswith(".") and ". " not in desc


def test_name_matches_its_directory_and_credits_pranav_first():
    assert _frontmatter("name") == SKILL_DIR.name
    assert _frontmatter("author").startswith("Pranav Krishna")


def test_modern_section_order():
    assert re.search(r"^# .+ Skill$", _text(), re.MULTILINE)
    headings = re.findall(r"^## (.+)$", _text(), re.MULTILINE)
    assert headings == ["When to Use", "Prerequisites", "How to Run", "Quick Reference",
                        "Procedure", "Pitfalls", "Verification"]


def test_every_tool_named_is_a_native_pc_lighting_tool():
    from toolsets import TOOLSETS
    named = set(re.findall(r"`(pc_[a-z_]+)`", _text()))
    registry = _tools()
    assert named
    for name in named:
        assert registry.get_schema(name) is not None, name
        assert name in TOOLSETS["pc_lighting"]["tools"], name


def test_every_action_in_the_quick_reference_exists_on_its_tool():
    registry = _tools()
    rows = re.findall(r"^\| `(pc_[a-z_]+)` \| ([a-z_ /]+) \|", _text(), re.MULTILINE)
    assert rows
    for tool, actions in rows:
        enum = registry.get_schema(tool)["parameters"]["properties"]["action"]["enum"]
        for action in actions.split("/"):
            assert action.strip() in enum, (tool, action)


def test_every_tool_action_is_documented():
    registry = _tools()
    rows = re.findall(r"^\| `(pc_[a-z_]+)` \| ([a-z_ /]+) \|", _text(), re.MULTILINE)
    documented = {(tool, a.strip()) for tool, actions in rows for a in actions.split("/")}
    for tool in {t for t, _ in rows}:
        for action in registry.get_schema(tool)["parameters"]["properties"]["action"]["enum"]:
            assert (tool, action) in documented, (tool, action)


def test_every_effect_and_part_the_server_knows_is_covered():
    sys.path.insert(0, str(REPO_ROOT / "webui"))
    from api.pc_lighting_store import EFFECTS, PARTS
    text = _text()
    for effect in EFFECTS:
        assert re.search(rf"^\| {effect} \|", text, re.MULTILINE), effect
    for part in PARTS:
        assert f"`{part}`" in text, part


def test_colour_table_sends_valid_hex():
    hexes = re.findall(r"^\| [^|]+ \| (#[0-9a-zA-Z]+) \|", _text(), re.MULTILINE)
    assert hexes
    for value in hexes:
        assert re.fullmatch(r"#[0-9a-f]{6}", value), value


def test_the_colour_table_says_what_the_tool_really_sends():
    import tools.pc_lighting_tool as t
    rows = re.findall(r"^\| ([^|]+) \| (#[0-9a-fA-F]{6}) \|", _text(), re.MULTILINE)
    assert rows
    for names, value in rows:
        for name in (n.strip() for n in names.split(",")):
            if name in t.NAMES:
                assert t.NAMES[name] == value.lower(), name

