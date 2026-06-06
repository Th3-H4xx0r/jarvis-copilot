"""SQLite store for Coding Sessions.

Mirrors the ``jarviscopilot_cli/kanban_db.py`` conventions: a SQLite db under the
JarvisCopilot home (``~/.jarviscopilot/coding_sessions.db``), idempotent schema
init, dict-row reads. Holds the first-class ``coding_projects`` and
``coding_sessions`` rows that back the Coding Sessions control plane.
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
CREATE TABLE IF NOT EXISTS coding_projects (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, repo_path TEXT NOT NULL,
  host TEXT NOT NULL DEFAULT 'server', default_branch TEXT,
  created_at REAL NOT NULL, sync_enabled INTEGER NOT NULL DEFAULT 0,
  sync_desktop_path TEXT, ignore_rules TEXT
);
CREATE TABLE IF NOT EXISTS coding_sessions (
  id TEXT PRIMARY KEY, project_id TEXT, host TEXT NOT NULL,
  cwd TEXT NOT NULL, worktree_path TEXT, branch TEXT, tmux_name TEXT,
  claude_session_id TEXT, status TEXT NOT NULL DEFAULT 'starting',
  title TEXT, source TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
  last_activity_at REAL, skip_permissions INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON coding_sessions(status);
"""

VALID_STATUSES = {"starting", "running", "idle", "stopped", "error"}


class CodingSessionStore:
    """Thin SQLite-backed store for coding projects and sessions."""

    def __init__(self, db_path: str | None = None) -> None:
        self.db_path = db_path or _default_db_path()
        self._init_schema()

    def _conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(self.db_path, timeout=30)
        c.row_factory = sqlite3.Row
        return c

    def _init_schema(self) -> None:
        with self._conn() as c:
            # WAL reduces "database is locked" under the WebUI + chat tools + a
            # future poller all writing concurrently.
            c.execute("PRAGMA journal_mode=WAL")
            c.executescript(_SCHEMA)
            # Migration: add columns to pre-existing dbs (CREATE IF NOT EXISTS
            # won't add a column to an existing table). Ignore "duplicate column".
            try:
                c.execute("ALTER TABLE coding_sessions ADD COLUMN "
                          "skip_permissions INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError:
                pass

    # --- sessions -----------------------------------------------------------

    def create_session(self, *, project_id, host, cwd, branch, tmux_name,
                       source, title, worktree_path=None,
                       skip_permissions=False) -> str:
        sid = "cs_" + uuid.uuid4().hex[:12]
        now = time.time()
        with self._conn() as c:
            c.execute(
                "INSERT INTO coding_sessions(id,project_id,host,cwd,worktree_path,"
                "branch,tmux_name,status,title,source,created_at,updated_at,"
                "skip_permissions) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, project_id, host, cwd, worktree_path, branch, tmux_name,
                 "starting", title, source, now, now,
                 1 if skip_permissions else 0))
        return sid

    def update_session(self, sid: str, **fields) -> None:
        allowed = {"status", "claude_session_id", "title", "tmux_name",
                   "worktree_path", "branch", "last_activity_at"}
        sets = {k: v for k, v in fields.items() if k in allowed}
        if "status" in sets and sets["status"] not in VALID_STATUSES:
            raise ValueError(f"invalid status: {sets['status']!r}")
        if not sets:
            return
        sets["updated_at"] = time.time()
        cols = ", ".join(f"{k}=?" for k in sets)
        with self._conn() as c:
            c.execute(f"UPDATE coding_sessions SET {cols} WHERE id=?",
                      (*sets.values(), sid))

    def get_session(self, sid: str) -> dict | None:
        with self._conn() as c:
            r = c.execute("SELECT * FROM coding_sessions WHERE id=?", (sid,)).fetchone()
        return dict(r) if r else None

    def delete_session(self, sid: str) -> None:
        with self._conn() as c:
            c.execute("DELETE FROM coding_sessions WHERE id=?", (sid,))

    def list_sessions(self, *, status: str | None = None) -> list[dict]:
        q = "SELECT * FROM coding_sessions"
        args: tuple = ()
        if status:
            q += " WHERE status=?"
            args = (status,)
        q += " ORDER BY created_at ASC"
        with self._conn() as c:
            return [dict(r) for r in c.execute(q, args).fetchall()]

    # --- projects -----------------------------------------------------------

    def create_project(self, *, name, repo_path, host="server",
                       default_branch=None) -> str:
        pid = "cp_" + uuid.uuid4().hex[:12]
        with self._conn() as c:
            c.execute(
                "INSERT INTO coding_projects(id,name,repo_path,host,default_branch,"
                "created_at) VALUES(?,?,?,?,?,?)",
                (pid, name, repo_path, host, default_branch, time.time()))
        return pid

    def get_project(self, pid: str) -> dict | None:
        with self._conn() as c:
            r = c.execute("SELECT * FROM coding_projects WHERE id=?", (pid,)).fetchone()
        return dict(r) if r else None

    def list_projects(self) -> list[dict]:
        with self._conn() as c:
            return [dict(r) for r in c.execute(
                "SELECT * FROM coding_projects ORDER BY created_at ASC").fetchall()]

    def delete_project(self, pid: str) -> None:
        with self._conn() as c:
            c.execute("DELETE FROM coding_projects WHERE id=?", (pid,))
