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


_STORE = None


def store():
    global _STORE
    if _STORE is None:
        from jarviscopilot_constants import get_hermes_home
        _STORE = GameStreamingStore(get_hermes_home() / "game_streaming")
    return _STORE
