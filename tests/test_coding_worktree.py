"""Tests for ``agent.coding_worktree`` — the git-worktree helper for Coding
Sessions.

These run against a REAL temporary git repository (created per-test under
``tmp_path``) and shell out to the real ``git`` binary, so they exercise the
genuine porcelain output and dirty-tree behaviour rather than a mock.

If ``git`` is not on PATH the whole module is skipped (it IS available in the
dev/CI environment, this is purely defensive).
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from agent import coding_worktree as cw

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None, reason="git binary not available"
)


def _run(args, cwd):
    subprocess.run(
        args, cwd=cwd, check=True, capture_output=True, text=True
    )


@pytest.fixture()
def repo(tmp_path):
    """A real, committed git repo. Returns its absolute path as a string."""
    root = tmp_path / "proj"
    root.mkdir()
    _run(["git", "init", "-q"], root)
    _run(["git", "config", "user.email", "test@example.com"], root)
    _run(["git", "config", "user.name", "Test User"], root)
    # A default branch name is deterministic regardless of host git config.
    _run(["git", "checkout", "-q", "-b", "main"], root)
    (root / "README.md").write_text("hello\n")
    _run(["git", "add", "README.md"], root)
    _run(["git", "commit", "-qm", "init"], root)
    return str(root.resolve())


def _is_worktree(path: str, repo_path: str) -> bool:
    """True if ``path`` appears in ``git worktree list`` for ``repo_path``.

    Compares resolved absolute paths so macOS ``/tmp`` -> ``/private/tmp``
    symlinking doesn't cause false negatives.
    """
    target = str(Path(path).resolve())
    for wt in cw.list_worktrees(repo_path):
        if str(Path(wt["path"]).resolve()) == target:
            return True
    return False


# ── add_worktree ────────────────────────────────────────────────────────────

def test_add_worktree_creates_real_worktree(repo):
    wt = cw.add_worktree(repo, "feature/login")

    assert os.path.isabs(wt)
    assert os.path.isdir(wt)
    # It's a checkout of our repo: the committed file is present.
    assert os.path.isfile(os.path.join(wt, "README.md"))
    # git agrees it is a worktree of this repo.
    assert _is_worktree(wt, repo)


def test_list_worktrees_includes_added(repo):
    wt = cw.add_worktree(repo, "topic")
    rows = cw.list_worktrees(repo)

    # Always at least the main worktree + the new one.
    assert len(rows) >= 2
    for r in rows:
        assert set(r.keys()) >= {"path", "branch", "head"}

    match = [
        r for r in rows
        if str(Path(r["path"]).resolve()) == str(Path(wt).resolve())
    ]
    assert len(match) == 1
    assert match[0]["branch"] == "topic"
    assert match[0]["head"]  # a non-empty sha


def test_add_worktree_branch_collision_suffixes(repo):
    first = cw.add_worktree(repo, "dup")
    # Same branch name again must NOT raise and must yield a different path.
    second = cw.add_worktree(repo, "dup")

    assert Path(first).resolve() != Path(second).resolve()

    rows = {
        str(Path(r["path"]).resolve()): r["branch"]
        for r in cw.list_worktrees(repo)
    }
    b1 = rows[str(Path(first).resolve())]
    b2 = rows[str(Path(second).resolve())]
    assert b1 == "dup"
    assert b2 != b1
    assert b2.startswith("dup")  # e.g. dup-2


def test_add_worktree_with_base(repo):
    # Base off the existing main branch explicitly; should succeed.
    wt = cw.add_worktree(repo, "from-main", base="main")
    assert _is_worktree(wt, repo)
    assert os.path.isfile(os.path.join(wt, "README.md"))


# ── remove_worktree ─────────────────────────────────────────────────────────

def test_remove_worktree_clean(repo):
    wt = cw.add_worktree(repo, "removeme")
    assert _is_worktree(wt, repo)

    cw.remove_worktree(wt)

    assert not _is_worktree(wt, repo)
    assert not os.path.isdir(wt)


def test_remove_dirty_worktree_raises_then_force_succeeds(repo):
    wt = cw.add_worktree(repo, "dirty")
    # Make the worktree dirty with an untracked file.
    (Path(wt) / "scratch.txt").write_text("uncommitted\n")

    with pytest.raises(Exception):
        cw.remove_worktree(wt, force=False)

    # Still present after the failed removal.
    assert _is_worktree(wt, repo)

    # Forced removal succeeds and the worktree is gone.
    cw.remove_worktree(wt, force=True)
    assert not _is_worktree(wt, repo)
    assert not os.path.isdir(wt)


def test_remove_nonexistent_worktree_raises(repo):
    bogus = os.path.join(repo, ".jc-worktrees", "does-not-exist")
    with pytest.raises(Exception):
        cw.remove_worktree(bogus, force=False)
