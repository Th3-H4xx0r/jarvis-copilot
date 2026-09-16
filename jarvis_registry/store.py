"""The registry store: spaces holding documents, records and their catalog.

One SQLite file (``~/.jarviscopilot/registry.db``) replaces the JSON and CSV files
integrations used to scatter through the workspace. A space belongs to one
integration and holds

* **documents** — ``(key -> JSON)``, overwritten in place: settings, cursors, the
  "last seen" state a monitor keeps;
* **records** — append-only rows with a timestamp: one casino session, one email
  digest, one workout. History is corrected by appending, never by rewriting;
* **a catalog** — a line of prose per document and collection, so the agent can see
  what exists without reading any of it.

Only the server opens this file: agent tools, the HTTP API and scripts that run on
the server. Nothing on a phone or pod touches it.
"""
from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Optional

SCHEMA_VERSION = 1
MAX_RECORD_BYTES = 256 * 1024
MAX_DOCUMENT_BYTES = 1024 * 1024
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.&-]{0,63}$")


class RegistryError(Exception):
    """A write the registry refuses: a bad name, an oversized body, bad JSON."""


class UnknownSpace(RegistryError):
    """A read for a space that was never created. Reads never create spaces."""


def default_path() -> Path:
    from jarviscopilot_constants import get_hermes_home

    return Path(get_hermes_home()) / "registry.db"


def slug(text: str) -> str:
    """A space id from a human name: "Casino Earnings" -> "casino-earnings"."""
    out = re.sub(r"[^a-z0-9]+", "-", (text or "").strip().lower()).strip("-")
    return out[:64] or "space"


# A record's own columns. A body may not carry these: `records()` returns the two
# merged, and a body key would otherwise hide the row's real id or time.
RESERVED_FIELDS = ("id", "ts", "source")
# One query's worth of records. 200 rows of 256 KB would be 50 MB assembled in
# memory and serialised into a single response.
MAX_RESULT_BYTES = 2 * 1024 * 1024


def _dumps(body: Any, limit: int, what: str) -> str:
    try:
        # No default= coercion: silently stringifying a set or a datetime is how a
        # store ends up with "{1, 2, 3}" in a field nobody can query. allow_nan=False
        # because NaN and Infinity are not JSON — SQLite tolerates them, JSON.parse
        # in the browser does not, and one such value breaks a whole collection's view.
        text = json.dumps(body, ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise RegistryError(f"{what} must be JSON-serialisable: {exc}") from exc
    if len(text.encode("utf-8")) > limit:
        raise RegistryError(f"{what} is larger than {limit // 1024} KB; store a summary or split it")
    return text


class Collection:
    """One record collection, for describing it in the catalog."""

    def __init__(self, space: "Space", name: str) -> None:
        self.space = space
        self.name = name

    def describe(self, description: str, fields: Optional[dict] = None) -> None:
        self.space._describe_collection(self.name, description, fields)

    def count(self) -> int:
        return self.space.count(self.name)


class Space:
    """One integration's corner of the registry."""

    def __init__(self, registry: "Registry", space_id: str) -> None:
        self.id = space_id
        self._reg = registry

    # ── the space itself ────────────────────────────────────────────────────
    def describe(self, description: str, name: Optional[str] = None,
                 icon: Optional[str] = None) -> None:
        sets, args = ["description = ?", "updated_at = ?"], [description, time.time()]
        if name is not None:
            sets.insert(0, "name = ?")
            args.insert(0, name)
        if icon is not None:
            sets.append("icon = ?")
            args.append(icon)
        args.append(self.id)
        self._reg._write(f"UPDATE spaces SET {', '.join(sets)} WHERE id = ?", args)

    def info(self) -> dict:
        row = self._reg._one("SELECT * FROM spaces WHERE id = ?", (self.id,))
        if row is None:
            raise UnknownSpace(self.id)
        return dict(row)

    # ── documents ───────────────────────────────────────────────────────────
    def put(self, key: str, body: Any, description: Optional[str] = None) -> None:
        """Write (or overwrite) a document."""
        if not _ID_RE.match(key or ""):
            raise RegistryError(f"document key {key!r}: lowercase letters, digits, - and _ only")
        text = _dumps(body, MAX_DOCUMENT_BYTES, "a document")
        self._reg._write(
            """INSERT INTO documents (space_id, key, body, description, updated_at)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(space_id, key) DO UPDATE SET
                 body = excluded.body,
                 description = COALESCE(excluded.description, documents.description),
                 updated_at = excluded.updated_at""",
            (self.id, key, text, description, time.time()),
        )

    def get(self, key: str, default: Any = None) -> Any:
        row = self._reg._one("SELECT body FROM documents WHERE space_id = ? AND key = ?",
                             (self.id, key))
        return default if row is None else json.loads(row["body"])

    def documents(self) -> list[dict]:
        rows = self._reg._all(
            "SELECT key, description, updated_at, length(body) AS bytes FROM documents "
            "WHERE space_id = ? ORDER BY key", (self.id,))
        return [dict(r) for r in rows]

    def delete_document(self, key: str) -> bool:
        return self._reg._write("DELETE FROM documents WHERE space_id = ? AND key = ?",
                                (self.id, key)) > 0

    # ── records ─────────────────────────────────────────────────────────────
    def append(self, collection: str, body: Any, ts: Optional[float] = None,
               source: str = "") -> int:
        """Add one record to a collection. Returns its id."""
        if not _ID_RE.match(collection or ""):
            raise RegistryError(f"collection {collection!r}: lowercase letters, digits, - and _ only")
        if not isinstance(body, dict):
            raise RegistryError("a record must be an object; wrap a bare value in one")
        clashes = [f for f in RESERVED_FIELDS if f in body]
        if clashes:
            raise RegistryError(
                f"a record may not carry {', '.join(clashes)} — those are the record's own "
                "columns, and a body field would hide the real value when it is read back")
        text = _dumps(body, MAX_RECORD_BYTES, "a record")
        now = time.time()
        self._reg._write(
            "INSERT OR IGNORE INTO collections (space_id, name, description, fields, updated_at) "
            "VALUES (?, ?, '', NULL, ?)", (self.id, collection, now))
        return self._reg._write(
            "INSERT INTO records (space_id, collection, ts, body, source, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (self.id, collection, float(ts if ts is not None else now), text, source, now),
            returns="lastrowid")

    def records(self, collection: str, since: Optional[float] = None,
                until: Optional[float] = None, where: Optional[dict] = None,
                limit: int = 100, newest_first: bool = True) -> list[dict]:
        """Records from a collection, newest first by default.

        ``where`` matches top-level fields exactly — ``{"game": "blackjack"}``.
        """
        order = "DESC" if newest_first else "ASC"
        sql = ["SELECT id, ts, body, source FROM records WHERE space_id = ? AND collection = ?"]
        args: list[Any] = [self.id, collection]
        if since is not None:
            sql.append("AND ts >= ?")
            args.append(float(since))
        if until is not None:
            sql.append("AND ts <= ?")
            args.append(float(until))
        for field, value in (where or {}).items():
            sql.append("AND json_extract(body, ?) = ?")
            args.extend([f"$.{field}", value])
        sql.append(f"ORDER BY ts {order}, id {order} LIMIT ?")
        args.append(max(1, min(int(limit), 1000)))
        rows = self._reg._all(" ".join(sql), args)
        out, budget = [], MAX_RESULT_BYTES
        for r in rows:
            budget -= len(r["body"])
            if budget < 0 and out:        # always return at least one record
                break
            body = json.loads(r["body"])
            if not isinstance(body, dict):   # a bare value, stored before that was refused
                body = {"value": body}
            # Row columns last: they are the record's real identity and time, and a
            # body that somehow carries one must not hide it.
            out.append({**body, "id": r["id"], "ts": r["ts"], "source": r["source"]})
        return out

    def delete_record(self, record_id: int) -> bool:
        """Remove one record. The importer uses it to undo a half-written file."""
        return self._reg._write("DELETE FROM records WHERE space_id = ? AND id = ?",
                                (self.id, int(record_id))) > 0

    def count(self, collection: str) -> int:
        row = self._reg._one(
            "SELECT COUNT(*) AS n FROM records WHERE space_id = ? AND collection = ?",
            (self.id, collection))
        return int(row["n"]) if row else 0

    def delete_collection(self, name: str) -> int:
        """Drop a collection: every record in it, and its entry in the catalog.

        Returns how many records went, so the caller can say what it removed.
        """
        gone = self._reg._write("DELETE FROM records WHERE space_id = ? AND collection = ?",
                                (self.id, name))
        self._reg._write("DELETE FROM collections WHERE space_id = ? AND name = ?",
                         (self.id, name))
        return gone

    def collection(self, name: str) -> Collection:
        return Collection(self, name)

    def collections(self) -> list[dict]:
        rows = self._reg._all(
            """SELECT c.name, c.description, c.fields,
                      (SELECT COUNT(*) FROM records r
                        WHERE r.space_id = c.space_id AND r.collection = c.name) AS count,
                      (SELECT MAX(ts) FROM records r
                        WHERE r.space_id = c.space_id AND r.collection = c.name) AS latest_ts
                 FROM collections c WHERE c.space_id = ? ORDER BY c.name""", (self.id,))
        out = []
        for r in rows:
            item = dict(r)
            item["fields"] = json.loads(item["fields"]) if item["fields"] else None
            out.append(item)
        return out

    def _describe_collection(self, name: str, description: str, fields: Optional[dict]) -> None:
        self._reg._write(
            """INSERT INTO collections (space_id, name, description, fields, updated_at)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(space_id, name) DO UPDATE SET
                 description = excluded.description,
                 fields = COALESCE(excluded.fields, collections.fields),
                 updated_at = excluded.updated_at""",
            (self.id, name, description,
             json.dumps(fields, ensure_ascii=False) if fields else None, time.time()))


class Registry:
    """The store. One instance per process; safe to share across threads."""

    def __init__(self, path: Optional[Path | str] = None) -> None:
        self.path = Path(path) if path else default_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False, timeout=15)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA busy_timeout=15000")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._migrate()

    # ── schema ──────────────────────────────────────────────────────────────
    def _migrate(self) -> None:
        with self._lock, self._conn:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS spaces (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    status      TEXT NOT NULL DEFAULT 'active',
                    icon        TEXT NOT NULL DEFAULT '',
                    created_at  REAL NOT NULL,
                    updated_at  REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS documents (
                    space_id    TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                    key         TEXT NOT NULL,
                    body        TEXT NOT NULL,
                    description TEXT,
                    updated_at  REAL NOT NULL,
                    PRIMARY KEY (space_id, key)
                );
                CREATE TABLE IF NOT EXISTS records (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    space_id   TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                    collection TEXT NOT NULL,
                    ts         REAL NOT NULL,
                    body       TEXT NOT NULL,
                    source     TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS records_by_time
                    ON records (space_id, collection, ts DESC);
                CREATE TABLE IF NOT EXISTS collections (
                    space_id    TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                    name        TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    fields      TEXT,
                    updated_at  REAL NOT NULL,
                    PRIMARY KEY (space_id, name)
                );
                """
            )
            row = self._conn.execute("SELECT version FROM schema_version").fetchone()
            if row is None:
                self._conn.execute("INSERT INTO schema_version (version) VALUES (?)",
                                   (SCHEMA_VERSION,))

    # ── spaces ──────────────────────────────────────────────────────────────
    def space(self, space_id: str, name: Optional[str] = None,
              description: str = "", icon: str = "") -> Space:
        """Open a space, creating it if it isn't there yet."""
        space_id = (space_id or "").strip().lower()
        if not _ID_RE.match(space_id):
            raise RegistryError(f"space id {space_id!r}: lowercase letters, digits, - and _ only")
        if name is not None and not _NAME_RE.match(name):
            raise RegistryError(f"space name {name!r} is not a plain name")
        now = time.time()
        self._write(
            """INSERT INTO spaces (id, name, description, status, icon, created_at, updated_at)
               VALUES (?, ?, ?, 'active', ?, ?, ?)
               ON CONFLICT(id) DO NOTHING""",
            (space_id, name or space_id, description, icon, now, now))
        return Space(self, space_id)

    def open(self, space_id: str) -> Space:
        """An existing space. Raises UnknownSpace — a read never creates one."""
        if self._one("SELECT id FROM spaces WHERE id = ?", (space_id,)) is None:
            raise UnknownSpace(f"no integration named {space_id!r}")
        return Space(self, space_id)

    def exists(self, space_id: str) -> bool:
        return self._one("SELECT id FROM spaces WHERE id = ?", (space_id,)) is not None

    def spaces(self, include_archived: bool = False) -> list[dict]:
        sql = "SELECT * FROM spaces"
        if not include_archived:
            sql += " WHERE status != 'archived'"
        sql += " ORDER BY name COLLATE NOCASE"
        return [dict(r) for r in self._all(sql, ())]

    def set_status(self, space_id: str, status: str) -> None:
        if status not in ("active", "paused", "archived"):
            raise RegistryError(f"status {status!r} must be active, paused or archived")
        self._write("UPDATE spaces SET status = ?, updated_at = ? WHERE id = ?",
                    (status, time.time(), space_id))

    def delete_space(self, space_id: str) -> bool:
        """Remove a space and everything in it."""
        return self._write("DELETE FROM spaces WHERE id = ?", (space_id,)) > 0

    # ── catalog ─────────────────────────────────────────────────────────────
    def catalog(self, space_id: Optional[str] = None) -> list[dict]:
        """Every space with its documents and collections — what exists, not what's in it."""
        out = []
        # An archived space is still readable and writable through open(), so the
        # catalog has to show it: "no such space" would have the agent make a duplicate.
        for row in self.spaces(include_archived=True):
            if space_id and row["id"] != space_id:
                continue
            space = Space(self, row["id"])
            out.append({
                "id": row["id"],
                "name": row["name"],
                "description": row["description"],
                "status": row["status"],
                "documents": space.documents(),
                "collections": space.collections(),
            })
        return out

    # ── plumbing ────────────────────────────────────────────────────────────
    def _write(self, sql: str, args: Iterable[Any] = (), returns: str = "rowcount") -> int:
        with self._lock, self._conn:
            cur = self._conn.execute(sql, tuple(args))
            return int(cur.lastrowid if returns == "lastrowid" else cur.rowcount)

    def _one(self, sql: str, args: Iterable[Any] = ()) -> Optional[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, tuple(args)).fetchone()

    def _all(self, sql: str, args: Iterable[Any] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, tuple(args)).fetchall()

    def close(self) -> None:
        with self._lock:
            self._conn.close()


_shared: Optional[Registry] = None
_shared_lock = threading.Lock()


def shared() -> Registry:
    """The process-wide registry — what tools and the API use."""
    global _shared
    with _shared_lock:
        if _shared is None:
            _shared = Registry()
        return _shared
