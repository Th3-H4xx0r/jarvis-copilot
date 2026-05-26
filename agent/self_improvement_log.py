"""Observability + revert for autonomous self-improvement.

Records every memory/skill change the agent makes to itself in a single
human-readable log under HERMES_HOME, and commits the change to the home
git repo (if one exists) so it can be reviewed and reverted. Best-effort
throughout: never raises into the caller.
"""
from __future__ import annotations

import logging
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

logger = logging.getLogger(__name__)

_LOG_NAME = "self_improvement.log"

# Body shape written by _append: "[origin] summary"  (summary may start with
# FAIL: or REJECTED:). Used by read_recent to parse the log back for the UIs.
_BODY_RE = re.compile(r"^\[(?P<origin>[^\]]+)\]\s*(?P<summary>.*)$", re.DOTALL)
_READ_TAIL_BYTES = 1_000_000  # only parse the tail of large logs


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


def log_noop(origin: str) -> None:
    """Record that a review ran but had nothing to save.

    Makes the loop's activity visible even on a no-op, so a user who did a task
    and saw no new skill can tell the difference between 'the review never
    fired' and 'it fired and decided nothing was worth saving'. Surfaced as a
    muted 'REVIEWED' entry in the UIs so it doesn't drown real learning events.

    Collapses consecutive no-ops: if the most recent log entry is already a
    NOOP, this is a no-op itself — so a quiet stretch leaves a single REVIEWED
    marker instead of flooding the feed and pushing real events out of the
    bounded tail.
    """
    try:
        path = _log_path()
        if path.exists():
            with open(path, "rb") as fh:
                fh.seek(0, 2)
                fh.seek(max(0, fh.tell() - 4096))
                tail = fh.read().decode("utf-8", errors="replace").splitlines()
            for ln in reversed(tail):
                if ln.strip():
                    if "] NOOP:" in ln:
                        return  # last entry is already a no-op — don't pile on
                    break
    except Exception:
        pass
    _append(f"[{origin}] NOOP: reviewed — nothing new to save")


def read_recent(limit: int = 50, home: Any = None) -> List[Dict[str, Any]]:
    """Return the most recent self-improvement events, NEWEST FIRST.

    Parses the log written by _append into structured rows for the UIs
    (webui endpoint, gateway RPC / TUI, mobile). Each row:
        {"ts": ISO str, "origin": str, "kind": "change"|"rejected"|"fail"|"noop",
         "text": summary str}
    ``home`` overrides the HERMES_HOME directory (the webui passes the active
    profile's home for parity with its other log endpoints); defaults to
    get_hermes_home(). Best-effort: returns [] on any error, never raises.
    """
    try:
        path = (Path(home) / _LOG_NAME) if home else _log_path()
        if not path.exists():
            return []
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            seeked = size > _READ_TAIL_BYTES
            fh.seek(max(0, size - _READ_TAIL_BYTES))
            data = fh.read()
        text = data.decode("utf-8", errors="replace")
        lines = [ln for ln in text.splitlines() if ln.strip()]
        if seeked and lines:
            lines = lines[1:]  # drop the possibly-partial first line
        entries: List[Dict[str, Any]] = []
        for ln in lines:
            ts, sep, body = ln.partition("  ")
            if not sep:
                ts, body = "", ln
            body = body.strip()
            m = _BODY_RE.match(body)
            origin = m.group("origin").strip() if m else ""
            summary = (m.group("summary").strip() if m else body)
            low = summary.lower()
            if low.startswith("fail:"):
                kind = "fail"
            elif low.startswith("rejected:"):
                kind = "rejected"
            elif low.startswith("noop:"):
                kind = "noop"
                summary = summary.split(":", 1)[1].strip()  # drop the NOOP: marker
            else:
                kind = "change"
            entries.append({
                "ts": ts.strip(),
                "origin": origin,
                "kind": kind,
                "text": summary,
            })
        entries.reverse()  # newest first
        # Always bound the result. A non-positive/None limit (e.g. a caller
        # passing a negative through) must not dump the entire tail.
        if not isinstance(limit, int) or limit <= 0:
            limit = 50
        return entries[:limit]
    except Exception as exc:
        logger.debug("read_recent failed: %s", exc)
        return []


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


__all__ = [
    "log_change", "log_failure", "log_rejected", "log_noop",
    "commit_home_change", "read_recent",
]
