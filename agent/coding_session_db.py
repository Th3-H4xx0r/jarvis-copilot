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
  last_activity_at REAL, skip_permissions INTEGER NOT NULL DEFAULT 0,
  sync_config TEXT, activity_state TEXT
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
            for ddl in (
                "ALTER TABLE coding_sessions ADD COLUMN "
                "skip_permissions INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE coding_sessions ADD COLUMN sync_config TEXT",
                # Device-discovery: which paired device a desktop/discovered
                # session lives on, and whether it was auto-discovered (not
                # named/owned by Jarvis) vs created here.
                "ALTER TABLE coding_sessions ADD COLUMN device_id TEXT",
                "ALTER TABLE coding_sessions ADD COLUMN "
                "external INTEGER NOT NULL DEFAULT 0",
                # Projects are keyed per (repo_path, device_id) so the same repo
                # on different paired devices stays distinct.
                "ALTER TABLE coding_projects ADD COLUMN device_id TEXT",
                # Live "activity state" of a running session (working | waiting |
                # idle), detected from the tmux pane. Separate from the lifecycle
                # `status` column so it never breaks running/stopped/error.
                "ALTER TABLE coding_sessions ADD COLUMN activity_state TEXT",
            ):
                try:
                    c.execute(ddl)
                except sqlite3.OperationalError:
                    pass
            # One project per (repo_path, device_id). The expression-based unique
            # index (COALESCE folds a NULL device_id to '') is what makes
            # get_or_create atomic under concurrency — two racing launches in the
            # same repo can't double-insert. IF NOT EXISTS keeps it idempotent on
            # an already-migrated db.
            try:
                c.execute(
                    "CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_path_device "
                    "ON coding_projects(repo_path, COALESCE(device_id,''))")
            except sqlite3.IntegrityError:
                # A pre-fix db may already hold duplicate (repo_path, device_id)
                # rows (from the old racy get_or_create). Collapse them onto the
                # oldest project, re-point that group's sessions, drop the dupes,
                # then build the index. Done in this same transaction.
                self._dedupe_projects(c)
                c.execute(
                    "CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_path_device "
                    "ON coding_projects(repo_path, COALESCE(device_id,''))")

    @staticmethod
    def _dedupe_projects(c: sqlite3.Connection) -> None:
        """Collapse duplicate (repo_path, COALESCE(device_id,'')) projects onto
        the earliest-created one, re-pointing their sessions, then delete the
        extras. Only invoked when the unique index can't be built yet."""
        rows = c.execute(
            "SELECT id, repo_path, COALESCE(device_id,'') AS dev FROM "
            "coding_projects ORDER BY created_at ASC, id ASC").fetchall()
        keep: dict[tuple, str] = {}
        for r in rows:
            key = (r["repo_path"], r["dev"])
            canonical = keep.get(key)
            if canonical is None:
                keep[key] = r["id"]
                continue
            c.execute("UPDATE coding_sessions SET project_id=? WHERE project_id=?",
                      (canonical, r["id"]))
            c.execute("DELETE FROM coding_projects WHERE id=?", (r["id"],))

    # --- sessions -----------------------------------------------------------

    def create_session(self, *, project_id, host, cwd, branch, tmux_name,
                       source, title, worktree_path=None,
                       skip_permissions=False, sync_config=None,
                       device_id=None, external=False, status="starting",
                       claude_session_id=None) -> str:
        sid = "cs_" + uuid.uuid4().hex[:12]
        now = time.time()
        with self._conn() as c:
            c.execute(
                "INSERT INTO coding_sessions(id,project_id,host,cwd,worktree_path,"
                "branch,tmux_name,status,title,source,created_at,updated_at,"
                "skip_permissions,sync_config,device_id,external,claude_session_id)"
                " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, project_id, host, cwd, worktree_path, branch, tmux_name,
                 status, title, source, now, now,
                 1 if skip_permissions else 0, sync_config,
                 device_id, 1 if external else 0, claude_session_id))
        return sid

    def update_session(self, sid: str, **fields) -> None:
        allowed = {"status", "claude_session_id", "title", "tmux_name",
                   "worktree_path", "branch", "last_activity_at",
                   "skip_permissions", "sync_config", "cwd",
                   "device_id", "external", "project_id", "source",
                   "activity_state"}
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

    def list_sessions(self, *, status: str | None = None,
                      project_id: str | None = None,
                      device_id: str | None = None) -> list[dict]:
        q = "SELECT * FROM coding_sessions"
        clauses, args = [], []
        if status:
            clauses.append("status=?"); args.append(status)
        if project_id is not None:
            clauses.append("project_id=?"); args.append(project_id)
        if device_id is not None:
            clauses.append("device_id=?"); args.append(device_id)
        if clauses:
            q += " WHERE " + " AND ".join(clauses)
        q += " ORDER BY created_at ASC"
        with self._conn() as c:
            return [dict(r) for r in c.execute(q, tuple(args)).fetchall()]

    # --- projects -----------------------------------------------------------

    def create_project(self, *, name, repo_path, host="server",
                       default_branch=None, device_id=None,
                       sync_enabled=False, sync_desktop_path=None,
                       ignore_rules=None) -> str:
        pid = "cp_" + uuid.uuid4().hex[:12]
        try:
            with self._conn() as c:
                c.execute(
                    "INSERT INTO coding_projects(id,name,repo_path,host,"
                    "default_branch,created_at,sync_enabled,sync_desktop_path,"
                    "ignore_rules,device_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (pid, name, repo_path, host, default_branch, time.time(),
                     1 if sync_enabled else 0, sync_desktop_path, ignore_rules,
                     device_id))
        except sqlite3.IntegrityError as e:
            # The (repo_path, device_id) unique index already holds a project for
            # this path. Surface a clear message instead of a raw SQLite error;
            # use get_or_create_project_for_path for idempotent reuse.
            raise ValueError(
                f"a project already exists for {repo_path!r}") from e
        return pid

    def get_or_create_project_for_path(self, *, repo_path, name=None,
                                       host="server", device_id=None,
                                       default_branch=None) -> str:
        """Idempotent project for a repo/folder. Keyed by (repo_path, device_id)
        so the SAME folder on the SAME device reuses one project (auto-grouping
        sessions), while the same path on a different device stays distinct.
        Returns the project id.

        Race-safe: the (repo_path, COALESCE(device_id,'')) unique index makes the
        INSERT atomic, so two concurrent launches in the same repo can't create
        two projects — the loser's INSERT raises IntegrityError and we re-select
        the winner's row."""
        dev = device_id or ""
        from pathlib import Path as _P

        def _select(c):
            return c.execute(
                "SELECT id FROM coding_projects WHERE repo_path=? "
                "AND COALESCE(device_id,'')=? ORDER BY created_at ASC LIMIT 1",
                (repo_path, dev)).fetchone()

        with self._conn() as c:
            row = _select(c)
            if row:
                return row["id"]
            pid = "cp_" + uuid.uuid4().hex[:12]
            try:
                c.execute(
                    "INSERT INTO coding_projects(id,name,repo_path,host,"
                    "default_branch,created_at,sync_enabled,sync_desktop_path,"
                    "ignore_rules,device_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (pid, name or _P(repo_path).name or repo_path, repo_path,
                     host, default_branch, time.time(), 0, None, None, device_id))
                return pid
            except sqlite3.IntegrityError:
                # Lost the race: another caller inserted the same key first.
                row = _select(c)
                if row:
                    return row["id"]
                raise

    def update_project(self, pid: str, **fields) -> None:
        allowed = {"name", "default_branch", "sync_enabled",
                   "sync_desktop_path", "ignore_rules", "repo_path", "host",
                   "device_id"}
        # sync_enabled is an INTEGER column: coerce True/False AND 1/0 to 0/1.
        # (The old ``1 if isinstance(v, bool)`` mapped BOTH True and False to 1,
        # so disabling sync silently re-enabled it.)
        sets = {k: (int(bool(v)) if k == "sync_enabled" else v)
                for k, v in fields.items() if k in allowed}
        if not sets:
            return
        cols = ", ".join(f"{k}=?" for k in sets)
        with self._conn() as c:
            try:
                c.execute(f"UPDATE coding_projects SET {cols} WHERE id=?",
                          (*sets.values(), pid))
            except sqlite3.IntegrityError:
                # Changing repo_path/device_id would collide with the
                # (repo_path, device_id) unique index — another project already
                # owns that key. Drop the keying fields and apply the rest so the
                # user's rename/sync edits still persist.
                safe = {k: v for k, v in sets.items()
                        if k not in ("repo_path", "device_id")}
                if not safe or set(safe) == {"updated_at"}:
                    return
                cols2 = ", ".join(f"{k}=?" for k in safe)
                c.execute(f"UPDATE coding_projects SET {cols2} WHERE id=?",
                          (*safe.values(), pid))

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
