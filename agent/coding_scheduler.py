"""Message scheduler for Coding Sessions.

A small, stdlib-only (``sqlite3`` + ``time``) scheduler that queues messages
to be delivered to a Coding Session either once or on a recurring interval.

It owns its OWN table (``coding_schedules``) created here with
``CREATE TABLE IF NOT EXISTS``, so it does not depend on editing the shared
``agent/coding_session_db.py`` schema. The db lives under the profile-scoped
JarvisCopilot home (``~/.jarviscopilot/coding_sessions.db``) by default, matching
the convention in ``coding_session_db.py``.

All time-dependent logic accepts an explicit ``now: float`` so callers (and
tests) drive the clock deterministically; nothing here reads the wall clock
in a way that affects scheduling decisions. ``time.time()`` is used only to
stamp ``created_at`` metadata.
"""
from __future__ import annotations

import os
import sqlite3
import time
import uuid
from pathlib import Path


def _default_db_path() -> str:
    """Resolve the db path under the profile-scoped JarvisCopilot home."""
    try:
        from jarviscopilot_constants import get_hermes_home

        home = Path(get_hermes_home())
    except Exception:
        home = Path(os.path.expanduser("~/.jarviscopilot"))
    home.mkdir(parents=True, exist_ok=True)
    return str(home / "coding_sessions.db")


_SCHEMA = """
CREATE TABLE IF NOT EXISTS coding_schedules (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  message TEXT NOT NULL,
  kind TEXT NOT NULL,              -- 'once' | 'recurring'
  next_run_at REAL NOT NULL,
  interval_seconds REAL,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_schedules_due
  ON coding_schedules(enabled, next_run_at);
CREATE INDEX IF NOT EXISTS idx_schedules_session
  ON coding_schedules(session_id);
"""

KIND_ONCE = "once"
KIND_RECURRING = "recurring"


class CodingScheduler:
    """SQLite-backed message scheduler for Coding Sessions.

    Owns the ``coding_schedules`` table. Time is always passed in explicitly
    to the due/fire methods so behaviour is deterministic and testable.
    """

    def __init__(self, db_path: str | None = None) -> None:
        self.db_path = db_path or _default_db_path()
        self._init_schema()

    # --- internals ----------------------------------------------------------

    def _conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(self.db_path, timeout=30)
        c.row_factory = sqlite3.Row
        return c

    def _init_schema(self) -> None:
        with self._conn() as c:
            # WAL keeps the poller and any concurrent writers from colliding.
            c.execute("PRAGMA journal_mode=WAL")
            c.executescript(_SCHEMA)

    @staticmethod
    def _row_to_dict(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "session_id": row["session_id"],
            "message": row["message"],
            "kind": row["kind"],
            "next_run_at": row["next_run_at"],
            "interval_seconds": row["interval_seconds"],
            "enabled": row["enabled"],
            "created_at": row["created_at"],
        }

    # --- scheduling ---------------------------------------------------------

    def schedule_once(
        self, session_id: str, message: str, run_at: float
    ) -> str:
        """Queue ``message`` for ``session_id`` to fire once at ``run_at``."""
        sid = "csch_" + uuid.uuid4().hex[:12]
        with self._conn() as c:
            c.execute(
                "INSERT INTO coding_schedules "
                "(id, session_id, message, kind, next_run_at, "
                " interval_seconds, enabled, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, 1, ?)",
                (
                    sid,
                    session_id,
                    message,
                    KIND_ONCE,
                    float(run_at),
                    None,
                    time.time(),
                ),
            )
        return sid

    def schedule_recurring(
        self,
        session_id: str,
        message: str,
        interval_seconds: float,
        first_run_at: float,
    ) -> str:
        """Queue ``message`` to fire at ``first_run_at`` then every interval."""
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be > 0")
        sid = "csch_" + uuid.uuid4().hex[:12]
        with self._conn() as c:
            c.execute(
                "INSERT INTO coding_schedules "
                "(id, session_id, message, kind, next_run_at, "
                " interval_seconds, enabled, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, 1, ?)",
                (
                    sid,
                    session_id,
                    message,
                    KIND_RECURRING,
                    float(first_run_at),
                    float(interval_seconds),
                    time.time(),
                ),
            )
        return sid

    # --- querying -----------------------------------------------------------

    def due(self, now: float) -> list[dict]:
        """Return enabled schedules whose ``next_run_at <= now``."""
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM coding_schedules "
                "WHERE enabled = 1 AND next_run_at <= ? "
                "ORDER BY next_run_at ASC, id ASC",
                (float(now),),
            ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def list_schedules(self, session_id: str | None = None) -> list[dict]:
        """List schedules, optionally filtered to one ``session_id``."""
        with self._conn() as c:
            if session_id is None:
                rows = c.execute(
                    "SELECT * FROM coding_schedules "
                    "ORDER BY created_at ASC, id ASC"
                ).fetchall()
            else:
                rows = c.execute(
                    "SELECT * FROM coding_schedules WHERE session_id = ? "
                    "ORDER BY created_at ASC, id ASC",
                    (session_id,),
                ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    # --- mutation -----------------------------------------------------------

    def mark_fired(self, id: str, now: float) -> None:
        """Record that schedule ``id`` fired at ``now``.

        For 'once' schedules: disable. For 'recurring': advance
        ``next_run_at`` by whole intervals until it is strictly past ``now``
        (so a long gap does not cause repeated catch-up firings), and keep
        the schedule enabled.
        """
        with self._conn() as c:
            row = c.execute(
                "SELECT kind, next_run_at, interval_seconds "
                "FROM coding_schedules WHERE id = ?",
                (id,),
            ).fetchone()
            if row is None:
                return
            if row["kind"] == KIND_RECURRING:
                interval = row["interval_seconds"]
                next_run = row["next_run_at"]
                # Always advance at least one interval; then catch up so the
                # next run lands strictly in the future relative to ``now``.
                next_run += interval
                if interval > 0 and next_run <= now:
                    # Number of additional whole intervals to clear ``now``.
                    steps = int((now - next_run) // interval) + 1
                    next_run += steps * interval
                c.execute(
                    "UPDATE coding_schedules SET next_run_at = ? WHERE id = ?",
                    (next_run, id),
                )
            else:
                c.execute(
                    "UPDATE coding_schedules SET enabled = 0 WHERE id = ?",
                    (id,),
                )

    def cancel(self, id: str) -> None:
        """Disable schedule ``id`` (idempotent)."""
        with self._conn() as c:
            c.execute(
                "UPDATE coding_schedules SET enabled = 0 WHERE id = ?",
                (id,),
            )

    # --- driving ------------------------------------------------------------

    def run_due(self, now: float, send) -> int:
        """Fire every due schedule via ``send(session_id, message)``.

        ``send`` is an injected callable so no real session is needed. Each
        due schedule is delivered, then ``mark_fired`` is applied. Returns the
        number of schedules fired.
        """
        fired = 0
        for sched in self.due(now=now):
            # Mark BEFORE send: a one-off that has been advanced/disabled can't
            # be re-delivered on the next tick even if the send (or this whole
            # iteration) fails. A delivered-but-failed message is lost — far
            # preferable to an infinite re-delivery spam loop. Per-item isolation
            # so one bad row doesn't abort the rest of the batch.
            try:
                self.mark_fired(sched["id"], now=now)
                send(sched["session_id"], sched["message"])
                fired += 1
            except Exception:
                continue
        return fired
