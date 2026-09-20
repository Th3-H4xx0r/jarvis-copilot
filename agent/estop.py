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

# "Already logged" flags keyed by (component, engaged_at), so a paused tick
# loop logs once per outage rather than once per tick.
_log_lock = threading.Lock()
_logged_components: set = set()


def _drop_component(component: str) -> None:
    """Forget every engagement recorded for ``component``. Caller holds the lock."""
    for key in [k for k in _logged_components if k[0] == component]:
        _logged_components.discard(key)


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


def _probe(path: Path) -> tuple:
    """``(present, errored)`` for one candidate path.

    ``Path.exists()`` swallows every OSError and answers False, so a sentinel
    we cannot stat (unreadable home, ELOOP symlink, dead mount) would read as
    "not paused" -- failing OPEN, which is the opposite of what an emergency
    stop owes you. Only "genuinely absent" errors mean absent; anything else
    is reported as an error so the caller can fail safe.
    """
    try:
        path.stat()
        return True, False
    except (FileNotFoundError, NotADirectoryError):
        return False, False
    except OSError:
        return False, True
    except AttributeError:
        # Non-Path test doubles.
        try:
            return bool(path.exists()), False
        except OSError:
            return False, True


def is_engaged() -> bool:
    """True if ANY candidate sentinel exists. Fails SAFE (True) on stat errors."""
    saw_stat_error = False
    for path in _candidate_sentinel_paths():
        present, errored = _probe(path)
        if present:
            return True
        saw_stat_error = saw_stat_error or errored
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


def disengage(fleet: bool = False) -> bool:
    """Remove the sentinel this process owns. Returns True if one was removed.

    Asymmetry matters here: ``engage()`` writes exactly one sentinel (this
    process's home), so lifting *every* candidate would let any profile clear
    the operator's fleet-wide stop at ``~/.jarviscopilot/ESTOP`` -- a worker
    silently resuming the whole fleet. By default a profile lifts only its own
    pause; ``is_engaged()`` keeps reporting True while the root stop stands,
    and clearing that one takes ``fleet=True`` (i.e. an explicit operator
    action from the root home).
    """
    paths = _candidate_sentinel_paths() if fleet else [sentinel_path()]
    lifted = False
    for path in paths:
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
        present, errored = _probe(path)
        if errored:
            return state
        if not present:
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
    state = get_state()
    if state is None:
        with _log_lock:
            _drop_component(component)
        return False
    # Key on the engagement, not just the component: a lift and a fresh pause
    # between two ticks is a NEW outage and deserves its own line, even though
    # no tick observed the gap.
    key = (component, state.get("engaged_at"))
    with _log_lock:
        first = key not in _logged_components
        _drop_component(component)
        _logged_components.add(key)
    if first:
        reason = state.get("reason")
        suffix = f" (reason: {reason})" if reason else ""
        logger.info(
            "%s paused by global emergency stop%s -- lift with "
            "`jarviscopilot unpause` (%s)",
            component, suffix, sentinel_path(),
        )
    return True
