"""Tests for the self-improvement observability + revert helper."""
from __future__ import annotations

import subprocess

import pytest


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    # get_hermes_home() reads HERMES_HOME fresh each call, so no reload needed.
    return tmp_path


def test_log_change_appends_line(home):
    from agent import self_improvement_log as sil
    sil.log_change("retrospective", "Memory updated · +1 lesson")
    log = (home / "self_improvement.log").read_text(encoding="utf-8")
    assert "retrospective" in log
    assert "Memory updated" in log
    assert "+1 lesson" in log


def test_log_failure_appends_line(home):
    from agent import self_improvement_log as sil
    sil.log_failure("retrospective", RuntimeError("boom"))
    log = (home / "self_improvement.log").read_text(encoding="utf-8")
    assert "FAIL" in log
    assert "boom" in log


def test_commit_home_change_commits_when_git_present(home):
    subprocess.run(["git", "init"], cwd=home, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=home, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=home, check=True)
    (home / "memories").mkdir()
    (home / "memories" / "MEMORY.md").write_text("hello", encoding="utf-8")
    from agent import self_improvement_log as sil
    assert sil.commit_home_change("retrospective: +1 lesson") is True
    out = subprocess.run(["git", "log", "--oneline"], cwd=home,
                         capture_output=True, text=True).stdout
    assert "retrospective: +1 lesson" in out


def test_commit_home_change_noop_without_git(home):
    from agent import self_improvement_log as sil
    # No .git in home → returns False, never raises.
    assert sil.commit_home_change("nothing") is False


def test_log_rejected_appends_line(home):
    from agent import self_improvement_log as sil
    sil.log_rejected("background_review", "invalid skill frontmatter: missing name")
    log = (home / "self_improvement.log").read_text(encoding="utf-8")
    assert "REJECTED" in log
    assert "invalid skill frontmatter" in log
    assert "background_review" in log
