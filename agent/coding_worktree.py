"""Git worktree helper for the Coding Sessions feature.

A Coding Session can run an agent against an *isolated* checkout of a project so
its edits don't collide with whatever the user is doing in the primary working
tree. This module is the thin, well-tested seam over ``git worktree`` that the
session manager / host drivers call.

Design notes / assumptions
--------------------------
- Worktrees are created in a sibling directory under the repo:
  ``<repo>/.jc-worktrees/<branch-slug>``. Keeping them inside the repo dir (but
  in a dedicated, git-ignored-by-convention folder) means they share the same
  filesystem/device as the repo (fast, no cross-device clone issues) and are
  trivially discoverable. The directory name is a slug of the branch; on
  collision a numeric suffix is appended to the *directory* name too.
- Branch-name collisions are resolved by suffixing the branch (``-2``, ``-3``,
  …) until ``git`` reports it as not-yet-existing, so calling ``add_worktree``
  repeatedly with the same logical name never raises.
- Everything shells out to the real ``git`` binary via ``subprocess`` with
  ``capture_output=True``; non-zero exit codes raise :class:`GitWorktreeError`
  carrying git's stderr so callers get an actionable message.

Pure stdlib — no third-party dependencies.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

__all__ = [
    "GitWorktreeError",
    "add_worktree",
    "list_worktrees",
    "remove_worktree",
]

# Directory (relative to the repo root) under which managed worktrees live.
WORKTREES_DIRNAME = ".jc-worktrees"


class GitWorktreeError(RuntimeError):
    """Raised when a ``git`` worktree operation fails."""


def _git(args: list[str], *, cwd: str | None = None) -> subprocess.CompletedProcess:
    """Run ``git <args>`` capturing output. Raises :class:`GitWorktreeError`
    (with git's stderr) on non-zero exit."""
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:  # git not installed
        raise GitWorktreeError("git executable not found on PATH") from exc
    if proc.returncode != 0:
        cmd = "git " + " ".join(args)
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        detail = stderr or stdout or f"exit code {proc.returncode}"
        raise GitWorktreeError(f"{cmd} failed: {detail}")
    return proc


def _slugify(branch: str) -> str:
    """Turn a branch name into a safe directory component.

    Replaces path separators and any non ``[A-Za-z0-9._-]`` char with ``-`` and
    collapses runs of ``-``. Never returns an empty string.
    """
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", branch)
    slug = re.sub(r"-{2,}", "-", slug).strip("-.")
    return slug or "worktree"


def _branch_exists(repo_path: str, branch: str) -> bool:
    """True if a local branch ``branch`` already exists in ``repo_path``."""
    proc = subprocess.run(
        ["git", "-C", repo_path, "show-ref",
         "--verify", "--quiet", f"refs/heads/{branch}"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


def _free_branch_name(repo_path: str, branch: str) -> str:
    """Return ``branch`` if free, else ``branch-2``, ``branch-3``, … until one
    is not an existing local branch."""
    if not _branch_exists(repo_path, branch):
        return branch
    n = 2
    while True:
        candidate = f"{branch}-{n}"
        if not _branch_exists(repo_path, candidate):
            return candidate
        n += 1


def _free_worktree_dir(repo_path: str, slug: str) -> Path:
    """Return an absolute, not-yet-existing directory for the worktree, under
    ``<repo>/.jc-worktrees/<slug>`` (suffixing on collision)."""
    base = Path(repo_path).resolve() / WORKTREES_DIRNAME
    base.mkdir(parents=True, exist_ok=True)
    candidate = base / slug
    if not candidate.exists():
        return candidate
    n = 2
    while True:
        candidate = base / f"{slug}-{n}"
        if not candidate.exists():
            return candidate
        n += 1


def add_worktree(repo_path: str, branch: str, base: str | None = None) -> str:
    """Create a new git worktree for ``repo_path`` on a new branch ``branch``.

    Runs ``git -C <repo> worktree add <wt_path> -b <branch> [base]``, placing the
    worktree under ``<repo>/.jc-worktrees/<branch-slug>``.

    If ``branch`` already exists as a local branch it is suffixed (``branch-2``,
    ``branch-3``, …) until free, so repeated calls with the same name never
    collide. ``base`` (a commit-ish to branch from) is optional; when omitted
    git branches from the current HEAD.

    Returns the absolute path of the created worktree.
    """
    if not branch or not branch.strip():
        raise GitWorktreeError("branch name must be non-empty")

    repo_abs = str(Path(repo_path).resolve())
    final_branch = _free_branch_name(repo_abs, branch)
    wt_dir = _free_worktree_dir(repo_abs, _slugify(final_branch))

    args = ["-C", repo_abs, "worktree", "add", str(wt_dir), "-b", final_branch]
    if base:
        args.append(base)
    _git(args)

    return str(wt_dir.resolve())


def list_worktrees(repo_path: str) -> list[dict]:
    """Return the worktrees of ``repo_path`` as a list of dicts.

    Each dict has ``path`` (absolute), ``branch`` (short branch name, or ``None``
    for a detached/bare worktree) and ``head`` (the commit sha, or ``None`` for a
    bare worktree). Parses ``git worktree list --porcelain``.
    """
    repo_abs = str(Path(repo_path).resolve())
    proc = _git(["-C", repo_abs, "worktree", "list", "--porcelain"])

    worktrees: list[dict] = []
    current: dict | None = None

    def _flush() -> None:
        nonlocal current
        if current is not None:
            worktrees.append(current)
            current = None

    for raw in proc.stdout.splitlines():
        line = raw.rstrip("\n")
        if line == "":
            _flush()
            continue
        if line.startswith("worktree "):
            _flush()
            current = {
                "path": line[len("worktree "):],
                "branch": None,
                "head": None,
            }
            continue
        if current is None:
            continue
        if line.startswith("HEAD "):
            current["head"] = line[len("HEAD "):]
        elif line.startswith("branch "):
            ref = line[len("branch "):]
            # Short-form the ref: refs/heads/foo -> foo
            if ref.startswith("refs/heads/"):
                ref = ref[len("refs/heads/"):]
            current["branch"] = ref
        elif line == "detached":
            current["branch"] = None
        elif line == "bare":
            current["branch"] = None
    _flush()

    return worktrees


def remove_worktree(worktree_path: str, *, force: bool = False) -> None:
    """Remove the worktree at ``worktree_path`` via ``git worktree remove``.

    Uses ``--force`` when ``force=True``. If the worktree is dirty (modified or
    untracked files) and ``force`` is False, git refuses; this surfaces as a
    :class:`GitWorktreeError` and the worktree is left intact.

    Resolution: ``git worktree remove`` must be run from inside the repo it
    belongs to. We locate the owning repo by reading the worktree's ``.git``
    pointer file; if that can't be resolved we fall back to running git from the
    worktree path itself.
    """
    wt_abs = str(Path(worktree_path).resolve())

    repo_cwd = _owning_main_repo(wt_abs) or wt_abs

    args = ["-C", repo_cwd, "worktree", "remove"]
    if force:
        args.append("--force")
    args.append(wt_abs)
    _git(args)


def _owning_main_repo(worktree_path: str) -> str | None:
    """Best-effort: return the main repo working dir that owns this worktree,
    so ``git worktree remove`` can be invoked from a valid repo context.

    A linked worktree has a ``.git`` *file* (not dir) of the form
    ``gitdir: /path/to/main/.git/worktrees/<name>``. From the main gitdir we can
    derive the main working tree. Returns ``None`` if anything is unparseable —
    callers fall back to the worktree path itself.
    """
    git_pointer = Path(worktree_path) / ".git"
    try:
        if git_pointer.is_file():
            text = git_pointer.read_text().strip()
            if text.startswith("gitdir:"):
                gitdir = text.split(":", 1)[1].strip()
                gitdir_path = Path(gitdir)
                # .../main/.git/worktrees/<name> -> main
                # Walk up to the ".git" component, its parent is the main wt.
                parts = gitdir_path.parts
                if ".git" in parts:
                    idx = len(parts) - 1 - parts[::-1].index(".git")
                    main_dir = Path(*parts[:idx]) if idx > 0 else None
                    if main_dir and main_dir.is_dir():
                        return str(main_dir.resolve())
    except OSError:
        return None
    return None
