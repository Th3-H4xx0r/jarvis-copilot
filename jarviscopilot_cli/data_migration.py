"""One-shot data-dir migration: ~/.hermes/ → ~/.jarviscopilot/.

Strategy: rename the data dir to the new name, then create a link at
the old path so existing code that still reads ``Path.home() / ".hermes"``
transparently lands on the new dir. New code reads from
``Path.home() / ".jarviscopilot"`` directly.

On Linux/macOS: symlink. Requires no privileges.
On Windows: directory junction (mklink /J). Does not need admin.

If migration can't be done (e.g. permissions, the new dir already
exists with content, etc.), the function logs and exits without
raising — original ``~/.hermes/`` is left untouched so the user's data
is never at risk.

Idempotent. Safe to call at every entry point.
"""
from __future__ import annotations

import logging
import os
import subprocess
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


def _home() -> Path:
    """Honor HOME / USERPROFILE so a custom-rooted run still works."""
    return Path.home()


def _is_link_or_junction(p: Path) -> bool:
    """True if *p* is a symlink or (on Windows) a directory junction."""
    try:
        if p.is_symlink():
            return True
    except OSError:
        return False
    if sys.platform == "win32":
        # is_symlink() returns False for NTFS junctions on some Python
        # versions. Use the reparse-point flag.
        try:
            import stat as _stat
            return bool(p.lstat().st_file_attributes & _stat.FILE_ATTRIBUTE_REPARSE_POINT)
        except (AttributeError, OSError):
            return False
    return False


def _make_directory_link(src: Path, dst: Path) -> bool:
    """Make *dst* a link/junction pointing at *src*. Returns True on success."""
    if sys.platform == "win32":
        # mklink /J doesn't need admin. /D (symlink) does on most setups.
        try:
            res = subprocess.run(
                ["cmd", "/c", "mklink", "/J", str(dst), str(src)],
                capture_output=True, text=True, timeout=10,
            )
            return res.returncode == 0
        except Exception as exc:
            logger.debug("mklink failed: %s", exc)
            return False
    try:
        os.symlink(str(src), str(dst), target_is_directory=True)
        return True
    except OSError as exc:
        logger.debug("symlink failed: %s", exc)
        return False


def migrate() -> dict:
    """Run the data-dir migration. Returns a status dict for logging.

    Status keys:
      - status: 'migrated' | 'already_done' | 'noop' | 'skipped' | 'failed'
      - detail: human-readable explanation
    """
    home = _home()
    old = home / ".hermes"
    new = home / ".jarviscopilot"

    # Already migrated: new dir exists, old is a link to it (or absent).
    if new.exists() and not _is_link_or_junction(new):
        if not old.exists():
            return {"status": "already_done", "detail": "new dir present, old absent"}
        if _is_link_or_junction(old):
            return {"status": "already_done", "detail": "new dir present, old is link"}
        # Both exist as real dirs — ambiguous; don't touch.
        return {
            "status": "skipped",
            "detail": f"both {old} and {new} exist as real directories; manual merge required",
        }

    # Nothing to migrate.
    if not old.exists():
        return {"status": "noop", "detail": "no legacy ~/.hermes/ to migrate"}

    # Old exists, new doesn't. Do the rename + link.
    if not new.parent.exists():
        try:
            new.parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return {"status": "failed", "detail": f"could not create {new.parent}: {exc}"}

    try:
        old.rename(new)
    except OSError as exc:
        return {
            "status": "failed",
            "detail": f"rename {old} -> {new} failed: {exc}",
        }

    # Back-compat link so legacy ~/.hermes/ readers keep working.
    if not _make_directory_link(new, old):
        # The rename succeeded but the link didn't. Code reading ~/.hermes/
        # will now fail to find data. We refuse to leave the user in this
        # half-migrated state — swap back.
        try:
            new.rename(old)
        except OSError as exc2:
            logger.error(
                "Migration partly-done and rollback failed: %s. Data is in %s; "
                "manually `mv %s %s` to restore.",
                exc2, new, new, old,
            )
            return {"status": "failed", "detail": "rename succeeded but link + rollback failed"}
        return {
            "status": "failed",
            "detail": (
                "rename succeeded but ~/.hermes/ → ~/.jarviscopilot/ link "
                "could not be created (rolled back to original location)"
            ),
        }

    return {
        "status": "migrated",
        "detail": f"~/.hermes/ moved to ~/.jarviscopilot/, ~/.hermes/ is now a link",
    }


def apply(*, quiet: bool = False) -> dict:
    """Run migrate() and log the result. Returns the status dict."""
    result = migrate()
    status = result.get("status")
    if status == "migrated" and not quiet:
        print(f"[migrate] {result['detail']}", flush=True)
    elif status == "failed" and not quiet:
        print(f"[migrate] FAILED: {result['detail']}", flush=True)
    elif status == "skipped" and not quiet:
        print(f"[migrate] skipped: {result['detail']}", flush=True)
    # 'already_done' and 'noop' are silent.
    return result


__all__ = ["apply", "migrate"]
