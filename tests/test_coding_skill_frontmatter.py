import re
from pathlib import Path

SKILL = (Path(__file__).resolve().parent.parent / "skills" / "jarviscopilot"
         / "coding-sessions" / "SKILL.md")


def test_skill_exists():
    assert SKILL.exists()


def test_skill_frontmatter_has_name_and_desc():
    text = SKILL.read_text(encoding="utf-8")
    assert text.startswith("---")
    fm = text.split("---", 2)[1]
    assert re.search(r"^name:\s*coding-sessions\s*$", fm, re.M)
    assert re.search(r"^description:\s*\S", fm, re.M)


def test_skill_mentions_the_tools():
    text = SKILL.read_text(encoding="utf-8")
    for tool in ("coding_session_launch", "coding_session_message",
                 "coding_session_list", "coding_session_stop"):
        assert tool in text
