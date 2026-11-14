"""Holo Drop's store: drops (and their files), bearings between devices, direct-LAN endpoints.

SQLite under the profile's home; payload files beside it. A drop's file is deleted 24 h after
it was sent (the row stays as history, marked expired); links and text stay in the row.
"""
from __future__ import annotations

import os
import secrets
import shutil
import sqlite3
import threading
import time
from pathlib import Path
from typing import Callable, Optional

PAYLOAD_TTL = 24 * 3600
_CHUNK = 1024 * 1024
_FIELDS = ("id", "kind", "sender", "target", "action", "pos_x", "pos_y", "name", "mime", "size",
           "text", "url", "title", "state", "outcome", "error", "created", "updated", "file",
           "expired", "direct")


class TooLarge(Exception):
    """The upload is over the size cap; nothing was written."""


class HoloStore:
    def __init__(self, root: Optional[Path] = None, clock: Callable[[], float] = time.time) -> None:
        if root is None:
            from jarviscopilot_constants import get_hermes_home
            root = Path(get_hermes_home()) / "holo_drop"
        self.root = Path(root)
        self.files = self.root / "files"
        self.files.mkdir(parents=True, exist_ok=True)
        self.clock = clock
        self._lock = threading.Lock()
        self._db = self.root / "holo_drop.db"
        with self._conn() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS drops (
                    id TEXT PRIMARY KEY, kind TEXT, sender TEXT, target TEXT, action TEXT,
                    pos_x REAL, pos_y REAL, name TEXT, mime TEXT, size INTEGER, text TEXT, url TEXT,
                    title TEXT, state TEXT, outcome TEXT, error TEXT, created REAL, updated REAL,
                    file TEXT, expired INTEGER DEFAULT 0, direct INTEGER DEFAULT 0);
                CREATE INDEX IF NOT EXISTS drops_target ON drops(target, state);
                CREATE TABLE IF NOT EXISTS bearings (
                    caller TEXT, device TEXT, deg REAL, confidence REAL, source TEXT,
                    distance_m REAL, at REAL, PRIMARY KEY (caller, device));
                CREATE TABLE IF NOT EXISTS lan (device TEXT PRIMARY KEY, url TEXT, token TEXT, expires REAL);
            """)

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self._db), timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    # ── drops ────────────────────────────────────────────────────────────────
    def create(self, kind: str, sender: str, target: str, action: str = "",
               position: Optional[dict] = None, name: str = "", mime: str = "", text: str = "",
               url: str = "", title: str = "", direct: bool = False) -> dict:
        drop_id = secrets.token_hex(8)
        now = self.clock()
        pos = position if isinstance(position, dict) else {}
        with self._lock, self._conn() as db:
            db.execute(
                "INSERT INTO drops (id, kind, sender, target, action, pos_x, pos_y, name, mime, size, text, url,"
                " title, state, created, updated, direct) VALUES (?,?,?,?,?,?,?,?,?,0,?,?,?, 'sent', ?, ?, ?)",
                (drop_id, kind, sender, target, action, _unit(pos.get("x")), _unit(pos.get("y")), name, mime,
                 text, url, title, now, now, int(bool(direct))))
        return self.get(drop_id)

    def attach_file(self, drop_id: str, rfile, length: int, max_bytes: int) -> dict:
        """Stream ``length`` bytes from ``rfile`` into the drop's file. Over the cap → TooLarge,
        refused before a byte is read."""
        if length > max_bytes:
            raise TooLarge(f"{length} bytes is over the {max_bytes // (1024 * 1024)} MB limit")
        path = self.files / drop_id
        tmp = path.with_suffix(".part")
        remaining = length
        try:
            with open(tmp, "wb") as out:
                while remaining > 0:
                    chunk = rfile.read(min(_CHUNK, remaining))
                    if not chunk:
                        raise ValueError("the upload ended early")
                    out.write(chunk)
                    remaining -= len(chunk)
            os.replace(tmp, path)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
        with self._lock, self._conn() as db:
            db.execute("UPDATE drops SET file = ?, size = ?, updated = ? WHERE id = ?",
                       (path.name, length, self.clock(), drop_id))
        return self.get(drop_id)

    def get(self, drop_id: str) -> Optional[dict]:
        with self._conn() as db:
            row = db.execute("SELECT * FROM drops WHERE id = ?", (drop_id,)).fetchone()
        return _row(row) if row else None

    def content_path(self, drop_id: str) -> Optional[Path]:
        d = self.get(drop_id)
        if not d or not d.get("file") or d.get("expired"):
            return None
        path = self.files / d["file"]
        return path if path.is_file() else None

    def set_state(self, drop_id: str, state: str, outcome: Optional[str] = None,
                  error: Optional[str] = None) -> Optional[dict]:
        with self._lock, self._conn() as db:
            db.execute("UPDATE drops SET state = ?, outcome = COALESCE(?, outcome), error = ?, updated = ?"
                       " WHERE id = ?", (state, outcome, error, self.clock(), drop_id))
        return self.get(drop_id)

    def pending_for(self, device: str) -> list[dict]:
        with self._conn() as db:
            rows = db.execute("SELECT * FROM drops WHERE target = ? AND state IN ('held', 'sent', 'delivered')"
                              " AND expired = 0 ORDER BY created", (device,)).fetchall()
        return [_row(r) for r in rows]

    def held(self) -> list[dict]:
        with self._conn() as db:
            rows = db.execute("SELECT * FROM drops WHERE state = 'held' AND expired = 0 ORDER BY created").fetchall()
        return [_row(r) for r in rows]

    def history(self, limit: int = 50) -> list[dict]:
        with self._conn() as db:
            rows = db.execute("SELECT * FROM drops ORDER BY created DESC, rowid DESC LIMIT ?", (int(limit),)).fetchall()
        out = []
        for r in rows:
            d = _row(r)
            d.pop("file", None)
            out.append(d)
        return out

    def sweep(self, now: Optional[float] = None) -> int:
        """Delete payloads older than 24 h (rows stay, marked expired). Returns how many."""
        now = self.clock() if now is None else now
        with self._conn() as db:
            rows = db.execute("SELECT id, file FROM drops WHERE expired = 0 AND created < ?",
                              (now - PAYLOAD_TTL,)).fetchall()
        for r in rows:
            if r["file"]:
                (self.files / r["file"]).unlink(missing_ok=True)
        with self._lock, self._conn() as db:
            db.executemany("UPDATE drops SET expired = 1, file = NULL, state = CASE WHEN state IN"
                           " ('held','sent','delivered') THEN 'expired' ELSE state END WHERE id = ?",
                           [(r["id"],) for r in rows])
        for part in self.files.glob("*.part"):
            if part.stat().st_mtime < now - 3600:
                part.unlink(missing_ok=True)
        return len(rows)

    # ── bearings ─────────────────────────────────────────────────────────────
    def put_bearings(self, caller: str, rows: list[dict]) -> None:
        now = self.clock()
        with self._lock, self._conn() as db:
            for b in rows:
                if not isinstance(b, dict) or not b.get("device"):
                    continue
                db.execute("INSERT OR REPLACE INTO bearings VALUES (?,?,?,?,?,?,?)",
                           (caller, str(b["device"]), float(b.get("deg") or 0), float(b.get("confidence") or 0),
                            str(b.get("source") or ""), b.get("distance_m"), float(b.get("at") or now)))

    def bearings_for(self, caller: str) -> dict[str, dict]:
        with self._conn() as db:
            rows = db.execute("SELECT * FROM bearings WHERE caller = ?", (caller,)).fetchall()
        return {r["device"]: {"deg": r["deg"], "confidence": r["confidence"], "source": r["source"],
                              "distance_m": r["distance_m"], "at": r["at"]} for r in rows}

    def clear_bearings_to(self, device: str) -> None:
        with self._lock, self._conn() as db:
            db.execute("DELETE FROM bearings WHERE device = ?", (device,))

    def clear_bearing(self, caller: str, device: str) -> None:
        with self._lock, self._conn() as db:
            db.execute("DELETE FROM bearings WHERE caller = ? AND device = ?", (caller, device))

    # ── direct LAN endpoints ─────────────────────────────────────────────────
    def set_lan(self, device: str, url: str, token: str, expires: float) -> None:
        with self._lock, self._conn() as db:
            db.execute("INSERT OR REPLACE INTO lan VALUES (?,?,?,?)", (device, url, token, float(expires)))

    def clear_lan(self, device: str) -> None:
        with self._lock, self._conn() as db:
            db.execute("DELETE FROM lan WHERE device = ?", (device,))

    def lan_for(self, device: str) -> Optional[dict]:
        with self._conn() as db:
            r = db.execute("SELECT * FROM lan WHERE device = ?", (device,)).fetchone()
        if not r or r["expires"] < self.clock():
            return None
        return {"url": r["url"], "token": r["token"], "expires": r["expires"]}

    def remove_all_files(self) -> None:
        shutil.rmtree(self.files, ignore_errors=True)
        self.files.mkdir(parents=True, exist_ok=True)


def _unit(v) -> Optional[float]:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return min(1.0, max(0.0, f))


def _row(r: sqlite3.Row) -> dict:
    d = {k: r[k] for k in _FIELDS}
    d["expired"] = bool(d["expired"])
    d["direct"] = bool(d["direct"])
    d["position"] = ({"x": d.pop("pos_x"), "y": d.pop("pos_y")}
                     if d.get("pos_x") is not None and d.get("pos_y") is not None
                     else (d.pop("pos_x"), d.pop("pos_y"), None)[2])
    d["from"] = d["sender"]
    return d


_store: Optional[HoloStore] = None
_store_lock = threading.Lock()


def store() -> HoloStore:
    global _store
    with _store_lock:
        if _store is None:
            _store = HoloStore()
        return _store
