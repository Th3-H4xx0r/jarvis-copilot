"""Global emergency stop (ESTOP) -- a resumable pause for NEW work only.

``jarviscopilot pause`` writes a sentinel at ``$HERMES_HOME/ESTOP``;
``jarviscopilot unpause`` removes it (``unpause``, not ``resume``: ``/resume``
already means "resume a named session"). While it exists the cron scheduler, the
kanban dispatcher and new gateway turns skip work; work already in flight is
never killed, and slash commands still reach you, so a pause cannot lock you
out of your own agent.

The check is one or two uncached ``os.stat`` calls (process home, plus the
fleet root when that is a different directory), cheap enough to sit in a tick
loop. The body is optional JSON ``{"reason", "engaged_at"}``; a corrupt or
empty file still counts as engaged, so ``touch ~/.jarviscopilot/ESTOP`` works
as a panic button. Ported from NousResearch/hermes-agent, which took the shape
from gastownhall/gastown estop.go (MIT).
"""

from __future__ import annotations

import json
import logging
import threading
from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

# The same profile-aware / fleet-root resolvers the file-safety guards use.
from agent.file_safety import (
    _hermes_home_path as _hermes_home,
    _hermes_root_path as _canonical_root,
)

SENTINEL_NAME = "ESTOP"

# Per-component "already logged for this engagement" flags, so a paused tick
# loop logs once rather than once per tick.
_log_lock = threading.Lock()
_logged_components: set = set()


def sentinel_path() -> Path:
    """Path of the sentinel this process would write on `jarviscopilot pause`."""
    return _hermes_home() / SENTINEL_NAME


def _candidate_sentinel_paths() -> List[Path]:
    """Profile home first, then the fleet root when it is a different directory.

    A profile gateway (HERMES_HOME=~/.jarviscopilot/profiles/<name>) must still
    honour an operator's ~/.jarviscopilot/ESTOP -- otherwise "stop everything"
    would quietly miss every profile.
    """
    primary = sentinel_path()
    try:
        root = _canonical_root() / SENTINEL_NAME
    except Exception:
        return [primary]
    try:
        distinct = root.resolve() != primary.resolve()
    except Exception:
        # Non-Path test doubles have no .resolve(); equality still dedupes.
        distinct = root != primary
    return [primary, root] if distinct else [primary]


def is_engaged() -> bool:
    """True if ANY candidate sentinel exists. Fails SAFE (True) on stat errors."""
    saw_stat_error = False
    for path in _candidate_sentinel_paths():
        try:
            if path.exists():
                return True
        except OSError:
            saw_stat_error = True
    return saw_stat_error


def engage(reason: Optional[str] = None) -> Path:
    """Create the sentinel. Idempotent; re-engaging refreshes the file."""
    path = sentinel_path()
    payload = {
        "engaged_at": datetime.now(timezone.utc).isoformat(),
        "reason": reason or None,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    except OSError:
        # Best effort: an empty or partial sentinel still pauses (fail safe).
        with suppress(OSError):
            path.touch(exist_ok=True)
    return path


def disengage() -> bool:
    """Remove every visible sentinel (process-local and fleet root)."""
    lifted = False
    for path in _candidate_sentinel_paths():
        try:
            path.unlink()
            lifted = True
        except (OSError, AttributeError):
            continue
    return lifted


def get_state() -> Optional[dict]:
    """``{"reason", "engaged_at"}`` while engaged, else None.

    An unreadable or corrupt body still reports engaged, with both fields None.
    """
    if not is_engaged():
        return None
    state = {"reason": None, "engaged_at": None}
    found = False
    for path in _candidate_sentinel_paths():
        try:
            if not path.exists():
                continue
        except OSError:
            return state
        except AttributeError:
            continue
        found = True
        with suppress(OSError, ValueError, AttributeError):
            raw = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                state = {
                    "reason": raw.get("reason") or None,
                    "engaged_at": raw.get("engaged_at") or None,
                }
                break
    return state if found else None


def paused_reply() -> Optional[str]:
    """Short user-facing notice for a new gateway turn, or None when running."""
    state = get_state()
    if state is None:
        return None
    tag = f" ({state['reason']})" if state.get("reason") else ""
    return (
        f"⏸️ JarvisCopilot is paused{tag}. New work is on hold; "
        "run `jarviscopilot unpause` or send /unpause to pick things back up."
    )


def check_paused(component: str, logger: logging.Logger) -> bool:
    """True when engaged, logging once per engagement per component.

    The flag re-arms after a resume, so the next pause logs again.
    """
    if not is_engaged():
        with _log_lock:
            _logged_components.discard(component)
        return False
    with _log_lock:
        first = component not in _logged_components
        _logged_components.add(component)
    if first:
        reason = (get_state() or {}).get("reason")
        suffix = f" (reason: {reason})" if reason else ""
        logger.info(
            "%s paused by global emergency stop%s -- lift with "
            "`jarviscopilot unpause` (%s)",
            component, suffix, sentinel_path(),
        )
    return True
