"""Capture the Claude Code session UUID for a JarvisCopilot Coding Session.

Claude Code writes each session transcript to::

    ~/.claude/projects/<ENCODED_CWD>/<session-uuid>.jsonl

where ``<ENCODED_CWD>`` is the project's absolute path with path separators
and dots encoded as dashes.

Encoding rule (slash->dash, dot->dash), as used in practice::

    /Users/jane/my-project   -> -Users-jane-my-project
    /home/x/.config/app      -> -home-x--config-app   (the "/." run -> "--")
    /Users/jane/my.proj      -> -Users-jane-my-proj

When Jarvis launches a coding session in a project ``cwd``, we recover the new
session UUID by finding the newest ``*.jsonl`` that appeared in that project's
transcript directory at or after the launch start time.

Pure stdlib (os, pathlib, time); no third-party dependencies.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

__all__ = [
    "encode_project_dir",
    "claude_projects_dir",
    "find_session_id",
    "wait_for_session_id",
]

# Grace applied to ``since_ts`` so a transcript created moments before our
# recorded launch time (clock skew / filesystem mtime granularity) still counts.
_MTIME_GRACE = 1.0


def encode_project_dir(cwd: str) -> str:
    """Encode an absolute project path the way Claude Code names its dir.

    Replaces every ``/`` and every ``.`` with ``-``.

    >>> encode_project_dir("/Users/jane/my.proj")
    '-Users-jane-my-proj'
    """
    return cwd.replace("/", "-").replace(".", "-")


def claude_projects_dir() -> Path:
    """Return the directory that holds per-project transcript folders.

    Honors ``CLAUDE_CONFIG_DIR`` if set (``<that>/projects``); otherwise
    defaults to ``~/.claude/projects``.
    """
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(config_dir) if config_dir else Path.home() / ".claude"
    return base / "projects"


def _project_transcript_dir(cwd: str, projects_dir: str | None) -> Path:
    base = Path(projects_dir) if projects_dir is not None else claude_projects_dir()
    return base / encode_project_dir(cwd)


def find_session_id(
    cwd: str,
    since_ts: float,
    *,
    projects_dir: str | None = None,
) -> str | None:
    """Return the UUID stem of the newest qualifying transcript, or ``None``.

    Looks in ``<projects_dir or claude_projects_dir()>/<encode_project_dir(cwd)>/``
    for ``*.jsonl`` files whose mtime is ``>= since_ts - 1.0`` (1s grace), and
    returns the stem (UUID) of the most-recently-modified one. Returns ``None``
    if the directory is missing or no file qualifies.
    """
    proj = _project_transcript_dir(cwd, projects_dir)
    try:
        entries = list(proj.glob("*.jsonl"))
    except OSError:
        return None
    if not entries:
        return None

    cutoff = since_ts - _MTIME_GRACE
    newest_stem: str | None = None
    newest_mtime = -1.0
    for path in entries:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if mtime < cutoff:
            continue
        if mtime > newest_mtime:
            newest_mtime = mtime
            newest_stem = path.stem
    return newest_stem


def wait_for_session_id(
    cwd: str,
    since_ts: float,
    *,
    projects_dir: str | None = None,
    timeout: float = 8.0,
    interval: float = 0.25,
    sleep=time.sleep,
) -> str | None:
    """Poll :func:`find_session_id` until it returns an id or ``timeout`` elapses.

    Polls immediately, then every ``interval`` seconds up to ``timeout``.
    ``sleep`` is injectable so tests can avoid real waiting (and can simulate a
    transcript appearing mid-wait). Returns the UUID stem, or ``None`` on
    timeout.
    """
    deadline = time.monotonic() + timeout
    while True:
        found = find_session_id(cwd, since_ts, projects_dir=projects_dir)
        if found is not None:
            return found
        if time.monotonic() >= deadline:
            return None
        sleep(interval)
