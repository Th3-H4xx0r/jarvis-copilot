"""Derived SQLite/FTS5 index over the markdown code-memory store.

The markdown files under ``$HERMES_HOME/code_memory/<slug>/{knowledge,sessions}.md``
remain the single source of truth (see :mod:`agent.code_memory`). This module
keeps a *disposable, rebuildable* SQLite index beside them at
``$HERMES_HOME/code_memory/index.db`` so recall can be token-cheap:

  - :func:`search`        -> compact ranked rows (id/type/ts/first_line), NO bodies
  - :func:`get_by_ids`    -> full bodies, fetched only for the ids the caller picked
  - :func:`counts` / :func:`stats` / :func:`project_counts` -> SQL aggregates

Everything here is best-effort and self-healing. The index is rebuilt lazily at
read time: every public call re-syncs any markdown file whose checksum changed
(cheap — the files are small), so the index also reflects out-of-band edits
(e.g. the ``distill`` pass). A build of ``sqlite3`` without FTS5 degrades to a
``LIKE`` scan; any hard failure lets callers fall back to the markdown parser in
:mod:`agent.code_memory` so recall never breaks.
"""
from __future__ import annotations

import hashlib
import re
import sqlite3
import threading
from pathlib import Path
from typing import Any

from agent import code_memory as cm

_LOCK = threading.RLock()
_FTS_OK: bool | None = None  # cached: does this sqlite build have FTS5?


# ── paths / helpers ──────────────────────────────────────────────────────────
def _db_path(home: Any = None) -> Path:
    return cm._root(home) / "index.db"


def _first_line(body: str, limit: int = 120) -> str:
    for ln in body.splitlines():
        s = ln.strip()
        if s:
            return s[:limit]
    return ""


def _fts_query(q: str | None) -> str:
    """Turn free text into a safe FTS5 MATCH expression (quoted AND-ed terms).

    Quoting each token avoids syntax errors from user input like ``prot=0`` or
    ``GET /backtests/{id}``. Returns "" when there's nothing searchable.
    """
    toks = re.findall(r"[A-Za-z0-9_]+", q or "")
    return " ".join(f'"{t}"' for t in toks)


def _connect(home: Any = None) -> sqlite3.Connection:
    path = _db_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path))
    con.row_factory = sqlite3.Row
    return con


def _has_fts(con: sqlite3.Connection) -> bool:
    global _FTS_OK
    if _FTS_OK is None:
        try:
            con.execute("DROP TABLE IF EXISTS _fts_probe")
            con.execute("CREATE VIRTUAL TABLE _fts_probe USING fts5(x)")
            con.execute("DROP TABLE IF EXISTS _fts_probe")
            _FTS_OK = True
        except Exception:
            _FTS_OK = False
    return _FTS_OK


def _ensure_schema(con: sqlite3.Connection) -> bool:
    con.execute(
        "CREATE TABLE IF NOT EXISTS entries("
        "id TEXT PRIMARY KEY, slug TEXT, kind TEXT, entry_type TEXT, "
        "ts TEXT, body TEXT, first_line TEXT)"
    )
    con.execute("CREATE INDEX IF NOT EXISTS ix_entries_slug_kind ON entries(slug, kind)")
    con.execute(
        "CREATE TABLE IF NOT EXISTS files("
        "slug TEXT, kind TEXT, checksum TEXT, PRIMARY KEY(slug, kind))"
    )
    fts = _has_fts(con)
    if fts:
        con.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts "
            "USING fts5(id UNINDEXED, body, first_line, tokenize='unicode61')"
        )
    return fts


# ── sync (markdown -> index), checksum-gated ─────────────────────────────────
def _index_file(con: sqlite3.Connection, slug: str, kind: str, home: Any) -> None:
    """Replace the index rows for one (slug, kind) markdown file from disk."""
    slug = cm._sanitize(slug)
    con.execute("DELETE FROM entries WHERE slug=? AND kind=?", (slug, kind))
    f = cm._file(slug, kind, home)
    if not f.exists():
        con.execute("DELETE FROM files WHERE slug=? AND kind=?", (slug, kind))
        return
    data = f.read_bytes()
    text = data.decode("utf-8", "replace")
    seen: dict[str, int] = {}
    rows = []
    for m in cm._entries_re(text).finditer(text):
        ts = m.group("ts")
        etype = m.group("type").strip()
        body = m.group("body").strip()
        ordinal = seen.get(ts, 0)
        seen[ts] = ordinal + 1
        eid = f"{slug}::{kind}::{ts}::{ordinal}"
        rows.append((eid, slug, kind, etype, ts, body, _first_line(body)))
    if rows:
        con.executemany(
            "INSERT OR REPLACE INTO entries(id,slug,kind,entry_type,ts,body,first_line) "
            "VALUES(?,?,?,?,?,?,?)", rows,
        )
    con.execute(
        "INSERT OR REPLACE INTO files(slug,kind,checksum) VALUES(?,?,?)",
        (slug, kind, hashlib.sha1(data).hexdigest()),
    )


def _rebuild_fts(con: sqlite3.Connection, fts: bool) -> None:
    if not fts:
        return
    con.execute("DELETE FROM entries_fts")
    con.execute(
        "INSERT INTO entries_fts(id, body, first_line) SELECT id, body, first_line FROM entries"
    )


def _on_disk(home: Any) -> set[tuple[str, str]]:
    out: set[tuple[str, str]] = set()
    for slug in cm._fs_slugs(home):
        for kind in cm.KINDS:
            if (cm._root(home) / cm._sanitize(slug) / f"{kind}.md").exists():
                out.add((slug, kind))
    return out


def _sync(con: sqlite3.Connection, fts: bool, home: Any) -> bool:
    """Re-index any file whose checksum changed; drop rows for vanished files.

    Returns True when anything changed (so the caller can rebuild FTS once).
    """
    on_disk = _on_disk(home)
    known = {(r["slug"], r["kind"]): r["checksum"]
             for r in con.execute("SELECT slug, kind, checksum FROM files")}
    changed = False
    for (slug, kind) in on_disk:
        f = cm._file(slug, kind, home)
        cs = hashlib.sha1(f.read_bytes()).hexdigest()
        if known.get((slug, kind)) != cs:
            _index_file(con, slug, kind, home)
            changed = True
    for (slug, kind) in set(known) - on_disk:
        con.execute("DELETE FROM entries WHERE slug=? AND kind=?", (slug, kind))
        con.execute("DELETE FROM files WHERE slug=? AND kind=?", (slug, kind))
        changed = True
    if changed:
        _rebuild_fts(con, fts)
    elif fts:
        # self-heal: rebuild FTS if it drifted from entries (partial write / corruption)
        ne = con.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
        nf = con.execute("SELECT COUNT(*) FROM entries_fts").fetchone()[0]
        if ne != nf:
            _rebuild_fts(con, fts)
            changed = True
    return changed


class _Session:
    """Open connection + ensured schema + fresh sync, as a context manager."""

    def __init__(self, home: Any):
        self.home = home
        self.con: sqlite3.Connection | None = None
        self.fts = False

    def __enter__(self) -> sqlite3.Connection:
        _LOCK.acquire()
        try:
            self.con = _connect(self.home)
            self.fts = _ensure_schema(self.con)
            _sync(self.con, self.fts, self.home)
            self.con.commit()
            return self.con
        except Exception:
            if self.con is not None:
                self.con.close()
            _LOCK.release()
            raise

    def __exit__(self, *exc) -> None:
        try:
            if self.con is not None:
                self.con.commit()
                self.con.close()
        finally:
            _LOCK.release()


# ── public read API ──────────────────────────────────────────────────────────
def search(slug: str | None = None, kind: str | None = None,
           entry_type: str | None = None, query: str | None = None,
           limit: int = 20, offset: int = 0, home: Any = None) -> list[dict]:
    """Compact ranked rows (id/slug/kind/entry_type/ts/first_line), NO bodies.

    Ranked by FTS bm25 when ``query`` is given (and FTS5 is available), else by
    recency (ts desc).
    """
    limit = max(1, int(limit))
    offset = max(0, int(offset))
    with _Session(home) as con:
        where, params = [], []
        if slug:
            where.append("e.slug=?"); params.append(cm._sanitize(slug))
        if kind:
            where.append("e.kind=?"); params.append(kind)
        if entry_type:
            where.append("e.entry_type=?"); params.append(entry_type)
        cols = "e.id, e.slug, e.kind, e.entry_type, e.ts, e.first_line"
        q = _fts_query(query) if query else ""
        if q and _has_fts(con):
            sql = (f"SELECT {cols} FROM entries_fts JOIN entries e ON e.id = entries_fts.id "
                   "WHERE entries_fts MATCH ? ")
            p = [q]
            if where:
                sql += "AND " + " AND ".join(where) + " "
                p += params
            sql += "ORDER BY bm25(entries_fts) LIMIT ? OFFSET ?"
            p += [limit, offset]
            rows = con.execute(sql, p).fetchall()
        else:
            if query:  # no FTS available -> substring scan (escape LIKE wildcards)
                esc = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                where.append("e.body LIKE ? ESCAPE '\\'"); params.append(f"%{esc}%")
            sql = f"SELECT {cols} FROM entries e "
            if where:
                sql += "WHERE " + " AND ".join(where) + " "
            # rowid tiebreak keeps order stable when entries share a timestamp
            # (rowid follows file/insertion order, so DESC = newest first).
            sql += "ORDER BY e.ts DESC, e.rowid DESC LIMIT ? OFFSET ?"
            params += [limit, offset]
            rows = con.execute(sql, params).fetchall()
        return [dict(r) for r in rows]


def get_by_ids(ids: list[str], home: Any = None) -> list[dict]:
    """Full rows (with ``content``) for the given ids, in the requested order."""
    ids = [i for i in (ids or []) if i]
    if not ids:
        return []
    with _Session(home) as con:
        marks = ",".join("?" * len(ids))
        found = {r["id"]: dict(r) for r in con.execute(
            f"SELECT id, slug, kind, entry_type, ts, body AS content FROM entries "
            f"WHERE id IN ({marks})", ids)}
        return [found[i] for i in ids if i in found]


def counts(slug: str | None = None, home: Any = None) -> dict:
    with _Session(home) as con:
        out = {"knowledge": 0, "sessions": 0}
        sql = "SELECT kind, COUNT(*) c FROM entries"
        params: list = []
        if slug:
            sql += " WHERE slug=?"; params.append(cm._sanitize(slug))
        sql += " GROUP BY kind"
        for r in con.execute(sql, params):
            out[r["kind"]] = r["c"]
        return out


def project_counts(home: Any = None) -> dict:
    """{slug: {'knowledge': n, 'sessions': m}} in one query."""
    with _Session(home) as con:
        out: dict[str, dict] = {}
        for r in con.execute("SELECT slug, kind, COUNT(*) c FROM entries GROUP BY slug, kind"):
            out.setdefault(r["slug"], {"knowledge": 0, "sessions": 0})[r["kind"]] = r["c"]
        return out


def stats(home: Any = None) -> dict:
    with _Session(home) as con:
        total_k = con.execute("SELECT COUNT(*) c FROM entries WHERE kind='knowledge'").fetchone()["c"]
        total_s = con.execute("SELECT COUNT(*) c FROM entries WHERE kind='sessions'").fetchone()["c"]
        by_type = {r["entry_type"]: r["c"] for r in con.execute(
            "SELECT entry_type, COUNT(*) c FROM entries WHERE kind='knowledge' GROUP BY entry_type")}
        nproj = con.execute("SELECT COUNT(DISTINCT slug) c FROM entries").fetchone()["c"]
        last = con.execute("SELECT MAX(ts) m FROM entries").fetchone()["m"]
        return {"projects": nproj, "knowledge": total_k, "sessions": total_s,
                "by_type": by_type, "last_activity": last}


def rebuild(home: Any = None) -> None:
    """Drop everything and re-sync from markdown (idempotent)."""
    with _LOCK:
        con = _connect(home)
        try:
            fts = _ensure_schema(con)
            con.execute("DELETE FROM entries")
            con.execute("DELETE FROM files")
            if fts:
                con.execute("DELETE FROM entries_fts")
            _sync(con, fts, home)
            con.commit()
        finally:
            con.close()
