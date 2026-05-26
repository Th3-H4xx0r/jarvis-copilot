"""Observability + revert for autonomous self-improvement.

Records every memory/skill change the agent makes to itself in a single
human-readable log under HERMES_HOME, and commits the change to the home
git repo (if one exists) so it can be reviewed and reverted. Best-effort
throughout: never raises into the caller.
"""
from __future__ import annotations

import logging
import subprocess
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

_LOG_NAME = "self_improvement.log"


def _home() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home()


def _log_path() -> Path:
    return _home() / _LOG_NAME


def _append(line: str) -> None:
    try:
        path = _log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{datetime.now().isoformat(timespec='seconds')}  {line}\n")
    except Exception as exc:  # never break the caller
        logger.debug("self_improvement_log append failed: %s", exc)


def log_change(origin: str, summary: str) -> None:
    """Record a successful self-improvement change (e.g. memory/skill write)."""
    _append(f"[{origin}] {summary}")


def log_failure(origin: str, exc: BaseException) -> None:
    """Record a failed self-improvement attempt so 'nothing happened' is diagnosable."""
    _append(f"[{origin}] FAIL: {type(exc).__name__}: {exc}")


def log_rejected(origin: str, detail: str) -> None:
    """Record a memory/skill write the agent attempted but that was REJECTED.

    e.g. invalid skill frontmatter, a name collision, or a memory char-limit
    hit. These never appear in the success summary, so without this a botched
    self-evolution attempt is a silent drop that looks like nothing happened.
    """
    _append(f"[{origin}] REJECTED: {detail}")


def commit_home_change(message: str) -> bool:
    """Best-effort: stage + commit all changes in HERMES_HOME. Returns True iff committed.

    No-ops (returns False) when the home is not a git repo or there is
    nothing to commit. Never raises.
    """
    home = _home()
    if not (home / ".git").exists():
        return False
    try:
        subprocess.run(["git", "-C", str(home), "add", "-A"],
                       check=True, capture_output=True)
        # Nothing staged → diff --cached --quiet exits 0; skip the commit.
        staged = subprocess.run(
            ["git", "-C", str(home), "diff", "--cached", "--quiet"],
            capture_output=True,
        )
        if staged.returncode == 0:
            return False
        subprocess.run(
            ["git", "-C", str(home), "commit", "-m", message,
             "--no-verify", "--quiet"],
            check=True, capture_output=True,
        )
        return True
    except Exception as exc:
        logger.debug("commit_home_change failed: %s", exc)
        return False


__all__ = ["log_change", "log_failure", "log_rejected", "commit_home_change"]
