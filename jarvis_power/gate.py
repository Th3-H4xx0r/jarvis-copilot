"""What refuses while a Power integration is off — and what never changes mid-chat.

- Routes: an off integration's ``route_prefixes`` answer 409 (``route_exempt`` stays open).
- Tools: calls into an off integration's toolsets are refused at once.
- New chats: an off integration's toolsets are left out. Each chat's list is fixed
  the first time it's asked for (``session_off_toolsets``), so switching anything
  later never changes an open chat's tools or system prompt — the prompt cache holds.
- Skills that belong to an off integration are hidden; its hooks don't fire.
"""
from __future__ import annotations

import json
import logging
import sqlite3
import threading
import time
from pathlib import Path
from typing import Callable, Optional

from jarvis_power import discovery, state

logger = logging.getLogger(__name__)

_SESSION_TTL = 30 * 86400
_db_lock = threading.Lock()


def _off():
    snap = state.snapshot()
    return [p for p in discovery.integrations().values() if not snap.get(p.id, True)]


def _under(path: str, prefix: str) -> bool:
    prefix = prefix.rstrip("/")
    return path == prefix or path.startswith(prefix + "/")


def route_block(path: str) -> Optional[dict]:
    """The 409 body for ``path`` when it belongs to an off integration, else None."""
    if _under(path, "/api/power"):
        return None
    best = None
    best_len = -1
    for p in _off():
        for prefix in p.route_prefixes:
            if _under(path, prefix) and len(prefix) > best_len:
                if any(_under(path, ex) for ex in p.route_exempt):
                    continue
                best, best_len = p, len(prefix)
    if best is None:
        return None
    return {"error": f"{best.name} is switched off", "power_off": best.id}


def tool_off_message(toolset: str) -> Optional[str]:
    if not toolset:
        return None
    for p in _off():
        if toolset in p.toolsets:
            return f"{p.name} is switched off"
    return None


def _live_off_toolsets() -> list[str]:
    return sorted({ts for p in _off() for ts in p.toolsets})


def _db_path() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return Path(get_hermes_home()) / "power_sessions.db"


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(str(_db_path()), timeout=5)
    conn.execute("CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, "
                 "toolsets TEXT NOT NULL, created_at REAL NOT NULL)")
    return conn


def session_off_toolsets(session_id: Optional[str]) -> list[str]:
    """The off toolsets a chat runs without — fixed the first time that chat asks."""
    if not session_id:
        return _live_off_toolsets()
    try:
        with _db_lock, _connect() as conn:
            row = conn.execute("SELECT toolsets FROM sessions WHERE session_id = ?",
                               (session_id,)).fetchone()
            if row is not None:
                return list(json.loads(row[0]))
            current = _live_off_toolsets()
            now = time.time()
            conn.execute("INSERT OR IGNORE INTO sessions VALUES (?, ?, ?)",
                         (session_id, json.dumps(current), now))
            conn.execute("DELETE FROM sessions WHERE created_at < ?", (now - _SESSION_TTL,))
            return current
    except Exception:
        logger.warning("power: session snapshot unavailable; using live state", exc_info=True)
        return _live_off_toolsets()


def remember_session(session_id: str, toolsets: list[str]) -> None:
    """Record a chat's list when it was resolved before the chat had an id."""
    if not session_id:
        return
    try:
        with _db_lock, _connect() as conn:
            conn.execute("INSERT OR IGNORE INTO sessions VALUES (?, ?, ?)",
                         (session_id, json.dumps(sorted(toolsets)), time.time()))
    except Exception:
        logger.warning("power: could not record session snapshot", exc_info=True)


def off_skill_names() -> set[str]:
    """Skills (directory names) that belong to an off integration."""
    off = _off()
    if not off:
        return set()
    from jarvis_registry import integrations
    names: set[str] = set()
    for p in off:
        for skill in integrations.skills_for(state.space_id_for(p.id)):
            names.add(skill["name"])
    return names


def gated(integration_id: str, fn: Callable) -> Callable:
    """``fn`` that does nothing (returns None) while the integration is off."""
    def wrapper(*args, **kwargs):
        if not state.is_on(integration_id):
            return None
        return fn(*args, **kwargs)
    wrapper.__name__ = getattr(fn, "__name__", "gated")
    wrapper.__wrapped__ = fn
    return wrapper
