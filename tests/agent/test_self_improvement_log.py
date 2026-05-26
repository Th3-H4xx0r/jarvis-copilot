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


def test_read_recent_parses_and_classifies(home):
    from agent import self_improvement_log as sil
    sil.log_change("background_review", "Skill created: ios-shortcuts")
    sil.log_rejected("background_review", "name collision: ios-shortcuts")
    sil.log_failure("retrospective", RuntimeError("boom"))
    rows = sil.read_recent(limit=10)
    assert len(rows) == 3
    # newest first
    assert rows[0]["kind"] == "fail" and rows[0]["origin"] == "retrospective"
    assert "boom" in rows[0]["text"]
    assert rows[1]["kind"] == "rejected" and "collision" in rows[1]["text"]
    assert rows[2]["kind"] == "change" and "Skill created" in rows[2]["text"]
    assert all(r["ts"] for r in rows)  # timestamps parsed


def test_read_recent_empty_when_no_log(home):
    from agent import self_improvement_log as sil
    assert sil.read_recent() == []


def test_read_recent_respects_limit(home):
    from agent import self_improvement_log as sil
    for i in range(10):
        sil.log_change("background_review", f"change {i}")
    rows = sil.read_recent(limit=3)
    assert len(rows) == 3
    assert rows[0]["text"] == "change 9"  # newest first


def test_read_recent_nonpositive_limit_is_bounded(home):
    from agent import self_improvement_log as sil
    for i in range(60):
        sil.log_change("background_review", f"c{i}")
    # 0 / negative must not dump the whole tail — clamp to the 50 default.
    assert len(sil.read_recent(limit=0)) == 50
    assert len(sil.read_recent(limit=-5)) == 50


def test_log_noop_classified_and_marker_stripped(home):
    from agent import self_improvement_log as sil
    sil.log_noop("background_review")
    rows = sil.read_recent(limit=5)
    assert len(rows) == 1
    assert rows[0]["kind"] == "noop"
    assert "nothing new to save" in rows[0]["text"]
    assert "NOOP" not in rows[0]["text"]  # the NOOP: marker is stripped for display


def test_log_noop_collapses_consecutive(home):
    from agent import self_improvement_log as sil
    sil.log_noop("background_review")
    sil.log_noop("background_review")
    sil.log_noop("background_review")
    assert len([r for r in sil.read_recent() if r["kind"] == "noop"]) == 1
    # a real event between no-ops resets the collapse
    sil.log_change("background_review", "Skill 'x' created")
    sil.log_noop("background_review")
    assert len([r for r in sil.read_recent() if r["kind"] == "noop"]) == 2
