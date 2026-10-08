"""Tests for skills/smart-home/jarvis-car-lights — its SKILL.md and its contract with the iOS app."""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "smart-home" / "jarvis-car-lights" / "SKILL.md"
DEVICE = REPO_ROOT / "ios_app" / "JarvisCopilot" / "Lights" / "CarLightsDevice.swift"


def test_description_is_one_short_sentence():
    match = re.search(r"^description: (.*)$", SKILL_MD.read_text(), re.MULTILINE)
    assert match and len(match.group(1)) <= 60 and match.group(1).endswith(".")


def test_every_lights_skill_in_the_doc_is_one_the_phone_advertises():
    documented = set(re.findall(r"`(lights_[a-z_]+)`", SKILL_MD.read_text()))
    advertised = set(re.findall(r'name: "(lights_[a-z_]+)"', DEVICE.read_text()))
    assert documented and documented <= advertised, documented - advertised


def test_every_lights_set_argument_in_the_doc_exists():
    text = DEVICE.read_text()
    block = text.split('name: "lights_set"', 1)[1].split("DeviceCapability(name:", 1)[0]
    for argument in ("target", "power", "color", "brightness", "white", "temperature", "effect", "speed",
                     "scene", "music", "mic_effect", "sensitivity"):
        assert f'"{argument}"' in block, argument


def test_modern_section_order():
    headings = re.findall(r"^## (.+)$", SKILL_MD.read_text(), re.MULTILINE)
    assert headings == ["When to Use", "Prerequisites", "How to Run", "Quick Reference",
                        "Procedure", "Pitfalls", "Verification"]
