"""Tests for skills/smart-home/jarvis-car — the car's SKILL.md and its contract with the iOS app."""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "smart-home" / "jarvis-car" / "SKILL.md"
CAR_DEVICE = REPO_ROOT / "ios_app" / "JarvisCopilot" / "Car" / "CarDevice.swift"


def frontmatter_field(name: str) -> str:
    match = re.search(rf"^{name}: (.*)$", SKILL_MD.read_text(), re.MULTILINE)
    assert match, name
    return match.group(1)


def test_description_is_one_short_sentence():
    description = frontmatter_field("description")
    assert len(description) <= 60
    assert description.endswith(".")


def test_every_car_skill_in_the_doc_is_one_the_phone_advertises():
    documented = set(re.findall(r"`(car_[a-z_]+)`", SKILL_MD.read_text()))
    advertised = set(re.findall(r'name: "(car_[a-z_]+)"', CAR_DEVICE.read_text()))
    assert documented, "the doc names the car skills"
    assert documented <= advertised, documented - advertised


def test_modern_section_order():
    headings = re.findall(r"^## (.+)$", SKILL_MD.read_text(), re.MULTILINE)
    assert headings == ["When to Use", "Prerequisites", "How to Run", "Quick Reference",
                        "Procedure", "Pitfalls", "Verification"]
