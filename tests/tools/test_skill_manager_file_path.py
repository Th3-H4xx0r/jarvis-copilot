"""Tests for skill_manage write_file path validation guidance."""
from __future__ import annotations

from tools.skill_manager_tool import _validate_file_path


def test_skill_md_write_file_directs_to_patch():
    # The autonomous review often tries to update the body via write_file on
    # SKILL.md; the error must steer it to action='patch'/'edit' so the update
    # isn't silently dropped (and self-corrects on retry).
    err = _validate_file_path("SKILL.md")
    assert err is not None
    assert "patch" in err and "write_file" in err
    # case-insensitive on the SKILL.md name
    assert _validate_file_path("skill.md") is not None


def test_support_file_paths_allowed():
    assert _validate_file_path("references/notes.md") is None
    assert _validate_file_path("scripts/run.sh") is None
    assert _validate_file_path("templates/x.txt") is None


def test_other_top_level_files_still_rejected_generically():
    err = _validate_file_path("random.txt")
    assert err is not None
    assert "must be under one of" in err.lower()


def test_traversal_blocked():
    assert _validate_file_path("../escape.md") is not None
