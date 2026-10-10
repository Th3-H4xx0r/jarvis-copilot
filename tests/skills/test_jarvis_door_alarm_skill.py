"""Tests for skills/smart-home/jarvis-door-alarm — the doc and its contract with the door_* tools."""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "smart-home" / "jarvis-door-alarm" / "SKILL.md"


def frontmatter_field(name: str) -> str:
    match = re.search(rf"^{name}: (.*)$", SKILL_MD.read_text(), re.MULTILINE)
    assert match, name
    return match.group(1)


def test_description_is_one_short_sentence():
    description = frontmatter_field("description")
    assert len(description) <= 60
    assert description.endswith(".")


def test_modern_section_order():
    headings = re.findall(r"^## (.+)$", SKILL_MD.read_text(), re.MULTILINE)
    assert headings == ["When to Use", "Prerequisites", "How to Run", "Quick Reference",
                        "Procedure", "Pitfalls", "Verification"]


def test_every_door_tool_is_documented_and_registered():
    from plugins.door_alarm.tools import TOOLS

    documented = set(re.findall(r"`(door_[a-z_]+)`", SKILL_MD.read_text()))
    assert documented == {name for name, *_ in TOOLS}


def test_doc_states_the_face_id_rule():
    text = SKILL_MD.read_text()
    assert "Face ID" in text and "pending_approval" in text
