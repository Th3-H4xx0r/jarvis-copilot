"""skills/computer-use: playbooks for browser and Mac work.

The contract that matters: every tool a playbook tells the model to call
exists (calling made-up tools cost turns in real chats), and each skill keeps
the house format.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
CATEGORY = REPO_ROOT / "skills" / "computer-use"
SKILLS = sorted(p.parent for p in CATEGORY.glob("*/SKILL.md"))
SECTIONS = ["## When to Use", "## Prerequisites", "## How to Run", "## Quick Reference",
            "## Procedure", "## Pitfalls", "## Verification"]

# Identifiers in backticks that name a tool the model would call.
_TOOL_PREFIXES = ("device_", "browser_", "chrome_", "spotify_", "coding_session_", "web_")
_TOOL_NAMES = {"computer_do", "cronjob", "form_ask", "memory_recall", "tool_search",
               "tool_call", "send_message", "clarify"}


def _known_tools() -> set[str]:
    names: set[str] = set()
    decl = re.compile(r'(?:\bname\s*=\s*|"name"\s*:\s*)"([a-z][a-z0-9_]+)"')
    for root in ("tools", "plugins", "agent"):
        for f in (REPO_ROOT / root).rglob("*.py"):
            names.update(decl.findall(f.read_text(errors="ignore")))
    device = re.compile(r'@skill\(\s*"([a-z][a-z0-9_]+)"')
    for f in (REPO_ROOT / "desktop_client" / "jc_client" / "skills").glob("*.py"):
        names.update(f"device_{n}" for n in device.findall(f.read_text()))
    return names


_ARGUMENTS = {"device_id"}


def _named_tools(text: str) -> set[str]:
    found = set()
    for ident in re.findall(r"`([a-z][a-z0-9_]*)", text):
        if ident.endswith("_") or ident in _ARGUMENTS:  # `browser_*`, `device_<name>`
            continue
        if ident in _TOOL_NAMES or ident.startswith(_TOOL_PREFIXES):
            found.add(ident)
    return found


def test_named_tools_reads_calls_not_patterns():
    text = "`device_open_url {url}` `browser_*` `device_<name>` `device_id` `computer_do`"
    assert _named_tools(text) == {"device_open_url", "computer_do"}


def test_the_category_has_its_playbooks():
    assert len(SKILLS) >= 2
    assert (CATEGORY / "DESCRIPTION.md").is_file()


@pytest.mark.parametrize("skill", SKILLS, ids=lambda p: p.name)
def test_frontmatter_name_and_short_description(skill):
    text = (skill / "SKILL.md").read_text()
    assert re.search(rf"^name: {re.escape(skill.name)}$", text, re.MULTILINE)
    desc = re.search(r'^description: "?(.*?)"?$', text, re.MULTILINE).group(1)
    assert len(desc) <= 60, (len(desc), desc)
    assert desc.endswith(".")


@pytest.mark.parametrize("skill", SKILLS, ids=lambda p: p.name)
def test_sections_in_house_order(skill):
    text = (skill / "SKILL.md").read_text()
    positions = [text.find(s) for s in SECTIONS]
    assert all(p >= 0 for p in positions), [s for s, p in zip(SECTIONS, positions) if p < 0]
    assert positions == sorted(positions)


@pytest.mark.parametrize("skill", SKILLS, ids=lambda p: p.name)
def test_every_named_tool_exists(skill):
    named = _named_tools((skill / "SKILL.md").read_text())
    missing = named - _known_tools()
    assert not missing, f"{skill.name} names tools that don't exist: {sorted(missing)}"


@pytest.mark.parametrize("skill", SKILLS, ids=lambda p: p.name)
def test_related_skills_resolve(skill):
    text = (skill / "SKILL.md").read_text()
    related = re.search(r"related_skills: \[(.*?)\]", text).group(1)
    bundled = {p.parent.name for p in (REPO_ROOT / "skills").rglob("SKILL.md")}
    bundled |= {p.parent.name for p in (REPO_ROOT / "optional-skills").rglob("SKILL.md")}
    # shopping-research and bitwarden live in his Jarvis home, not the repo.
    outside = {"shopping-research", "bitwarden"}
    for name in (n.strip() for n in related.split(",") if n.strip()):
        assert name in bundled or name in outside, name
