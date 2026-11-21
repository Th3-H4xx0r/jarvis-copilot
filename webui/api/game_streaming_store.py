"""Game streaming store: paired-device cache, live state, session history (SQLite, WAL)."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from contextlib import closing
from pathlib import Path
from typing import Callable


class GameStreamingStore:
    def __init__(self, root, clock: Callable[[], float] = time.time):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._db = self.root / "game_streaming.db"
        self.clock = clock
        self._lock = threading.Lock()
        with closing(self._conn()) as db, db:
            db.executescript(
                "CREATE TABLE IF NOT EXISTS paired (uuid TEXT PRIMARY KEY, name TEXT, data TEXT);"
                "CREATE TABLE IF NOT EXISTS live (id INTEGER PRIMARY KEY CHECK (id=1), data TEXT);"
                "CREATE TABLE IF NOT EXISTS sessions (t REAL, kind TEXT, client TEXT, app TEXT, data TEXT);"
                "CREATE TABLE IF NOT EXISTS targets (name TEXT PRIMARY KEY, kind TEXT, host TEXT, tv_addr TEXT, pos INTEGER);"
            )

    def _conn(self):
        conn = sqlite3.connect(str(self._db), timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def upsert_paired(self, devices):
        with self._lock, closing(self._conn()) as db, db:
            db.execute("DELETE FROM paired")
            for d in devices or []:
                db.execute(
                    "INSERT OR REPLACE INTO paired (uuid, name, data) VALUES (?, ?, ?)",
                    (d.get("uuid") or d.get("name"), d.get("name"), json.dumps(d)))

    def get_paired(self):
        with closing(self._conn()) as db:
            rows = db.execute("SELECT data FROM paired ORDER BY name").fetchall()
        return [json.loads(r["data"]) for r in rows]

    def known_certs(self):
        return {d.get("name") for d in self.get_paired() if d.get("name")}

    def set_live(self, state):
        with self._lock, closing(self._conn()) as db, db:
            db.execute("INSERT OR REPLACE INTO live (id, data) VALUES (1, ?)",
                       (json.dumps(state or {}),))

    def get_live(self):
        with closing(self._conn()) as db:
            row = db.execute("SELECT data FROM live WHERE id=1").fetchone()
        if not row:
            return {"active": False, "client": None, "app": None}
        return json.loads(row["data"])

    def record_session(self, evt):
        e = evt or {}
        with self._lock, closing(self._conn()) as db, db:
            db.execute("INSERT INTO sessions (t, kind, client, app, data) VALUES (?, ?, ?, ?, ?)",
                       (self.clock(), e.get("kind"), e.get("client"), e.get("app"), json.dumps(e)))

    def recent_sessions(self, limit=20):
        with closing(self._conn()) as db:
            rows = db.execute(
                "SELECT t, data FROM sessions ORDER BY t DESC, rowid DESC LIMIT ?", (limit,)).fetchall()
        return [dict(json.loads(r["data"]), t=r["t"]) for r in rows]

    # ── target devices (structured; replaces the old raw JSON setting) ────────
    def set_targets(self, targets):
        """Replace the whole target list. Each row: {name, kind, host?, tv_addr?}.
        host is an optional per-device override — blank means the server fills the PC's
        known Moonlight address at read time. Rows without a name are dropped."""
        with self._lock, closing(self._conn()) as db, db:
            db.execute("DELETE FROM targets")
            for i, t in enumerate(targets or []):
                name = str((t or {}).get("name") or "").strip()
                if not name:
                    continue
                db.execute(
                    "INSERT OR REPLACE INTO targets (name, kind, host, tv_addr, pos) VALUES (?, ?, ?, ?, ?)",
                    (name, str(t.get("kind") or ""), str(t.get("host") or ""),
                     str(t.get("tv_addr") or ""), i))

    def get_targets(self):
        """The stored rows, in order. host/tv_addr are present only when set."""
        with closing(self._conn()) as db:
            rows = db.execute("SELECT name, kind, host, tv_addr FROM targets ORDER BY pos, name").fetchall()
        out = []
        for r in rows:
            t = {"name": r["name"], "kind": r["kind"] or ""}
            if r["host"]:
                t["host"] = r["host"]
            if r["tv_addr"]:
                t["tv_addr"] = r["tv_addr"]
            out.append(t)
        return out

    def has_targets(self):
        with closing(self._conn()) as db:
            return db.execute("SELECT COUNT(*) AS c FROM targets").fetchone()["c"] > 0


_STORE = None


def store():
    global _STORE
    if _STORE is None:
        from jarviscopilot_constants import get_hermes_home
        _STORE = GameStreamingStore(get_hermes_home() / "game_streaming")
    return _STORE
