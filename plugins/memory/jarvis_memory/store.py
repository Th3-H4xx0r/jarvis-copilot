"""SQLite + markdown-vault storage for jarvis_memory.

The markdown vault under ``<vault_dir>/<namespace>/<id>.md`` is the durable
source of truth for each chunk body; SQLite holds the index, metadata, vectors
(brute-force cosine), an FTS5 keyword index, and a key-value store. This is the
only module that touches SQLite.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

import numpy as np

from .textq import content_tokens, fts_query
from .vecindex import VectorIndex

logger = logging.getLogger(__name__)
GLOBAL_NS = "global"
# Keyword hit found only by the substring fallback (no FTS strength to go on).
LIKE_SCORE = 0.2


@dataclass
class Chunk:
    id: str
    namespace: str
    body: str
    source: str
    created_at: float
    score: float
    tags: str = ""
    content_path: str = ""
    status: str = "active"
    event_start: Optional[float] = None
    event_end: Optional[float] = None
    valid_to: Optional[float] = None
    superseded_by: str = ""
    importance: Optional[int] = None
    kind: str = ""
    pinned: int = 0
    slots: str = ""
    source_ref: str = ""


# A row is visible to every read unless cleanup or a merge hid it. IFNULL so a
# row written before the column existed counts as active.
_ACTIVE = "IFNULL(status,'active') != 'hidden'"
_C_ACTIVE = "IFNULL(c.status,'active') != 'hidden'"

# Map columns added to `chunks` after the first release (ALTER TABLE on open).
_MAP_COLUMNS = [
    ("status", "TEXT DEFAULT 'active'"), ("event_start", "REAL"), ("event_end", "REAL"),
    ("valid_to", "REAL"), ("superseded_by", "TEXT"), ("importance", "INTEGER"),
    ("kind", "TEXT"), ("pinned", "INTEGER DEFAULT 0"), ("slots", "TEXT DEFAULT ''"),
    ("source_ref", "TEXT DEFAULT ''"), ("enriched_at", "REAL"), ("stored_at", "REAL"),
]
_SETTABLE = {name for name, _ in _MAP_COLUMNS} - {"status", "stored_at"}


def chunk_id(namespace: str, source: str, body: str) -> str:
    h = hashlib.sha256(f"{namespace}\x1e{source}\x1e{body}".encode("utf-8")).hexdigest()
    return f"c_{h[:24]}"


def sanitize_ns(ns: str) -> str:
    ns = ns or GLOBAL_NS
    return "".join(ch if (ch.isalnum() or ch in "._-") else "_" for ch in ns) or GLOBAL_NS


def _pack(vec) -> bytes:
    return np.asarray(vec, dtype=np.float32).tobytes()


def _unpack(blob: bytes) -> "np.ndarray":
    return np.frombuffer(blob, dtype=np.float32)


def _dedup_ci(items):
    seen, out = set(), []
    for it in items:
        k = it.lower()
        if k and k not in seen:
            seen.add(k)
            out.append(it)
    return out


def _like_prefix(prefix: str) -> str:
    """A LIKE pattern for strings starting with ``prefix`` (used with ESCAPE)."""
    return prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def _entity_row(r) -> dict:
    d = dict(r)
    d["aliases"] = json.loads(d.get("aliases") or "[]")
    return d


class MemoryStore:
    def __init__(self, db_path, vault_dir):
        self.db_path = str(db_path)
        self.vault_dir = Path(vault_dir)
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        self.vault_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA busy_timeout=15000")
        self._has_fts = False
        self._vindex: dict = {}
        self._bootstrap()

    def _bootstrap(self):
        with self._lock:
            c = self._conn
            c.executescript(
                """
                CREATE TABLE IF NOT EXISTS chunks(
                  id TEXT PRIMARY KEY, namespace TEXT NOT NULL, body TEXT NOT NULL,
                  content_path TEXT, content_sha256 TEXT, source TEXT,
                  created_at REAL NOT NULL, score REAL DEFAULT 0, tags TEXT DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS ix_chunks_ns ON chunks(namespace);
                CREATE TABLE IF NOT EXISTS vectors(
                  chunk_id TEXT NOT NULL, namespace TEXT NOT NULL, embedding BLOB NOT NULL,
                  model_signature TEXT NOT NULL, dim INTEGER NOT NULL,
                  PRIMARY KEY(chunk_id, model_signature)
                );
                CREATE INDEX IF NOT EXISTS ix_vectors_ns_sig ON vectors(namespace, model_signature);
                CREATE TABLE IF NOT EXISTS kv(
                  namespace TEXT NOT NULL, key TEXT NOT NULL, value TEXT,
                  updated_at REAL NOT NULL, PRIMARY KEY(namespace, key)
                );
                """
            )
            try:
                c.execute(
                    "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts "
                    "USING fts5(chunk_id UNINDEXED, body, tokenize='unicode61')"
                )
                self._has_fts = True
            except sqlite3.OperationalError:
                self._has_fts = False
            c.commit()
            self._migrate()

    def _migrate(self):
        """Bring an older database up to the map schema, in place."""
        c = self._conn
        have = {r[1] for r in c.execute("PRAGMA table_info(chunks)")}
        for name, decl in _MAP_COLUMNS:
            if name not in have:
                c.execute(f"ALTER TABLE chunks ADD COLUMN {name} {decl}")
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS memory_sources(
              memory_id TEXT NOT NULL, source TEXT NOT NULL, tags TEXT DEFAULT '',
              PRIMARY KEY(memory_id, source)
            );
            CREATE INDEX IF NOT EXISTS ix_sources_source ON memory_sources(source);
            CREATE TABLE IF NOT EXISTS entities(
              id TEXT PRIMARY KEY, namespace TEXT NOT NULL, type TEXT NOT NULL,
              canonical TEXT NOT NULL, aliases TEXT DEFAULT '[]', summary TEXT DEFAULT '',
              event_start REAL, event_end REAL, pinned INTEGER DEFAULT 0, updated_at REAL
            );
            CREATE TABLE IF NOT EXISTS memory_entities(
              memory_id TEXT NOT NULL, entity_id TEXT NOT NULL, role TEXT NOT NULL DEFAULT '',
              PRIMARY KEY(memory_id, entity_id, role)
            );
            CREATE INDEX IF NOT EXISTS ix_me_entity ON memory_entities(entity_id);
            CREATE TABLE IF NOT EXISTS map_queue(
              memory_id TEXT PRIMARY KEY, queued_at REAL NOT NULL, attempts INTEGER DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS recall_traces(
              id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, session_id TEXT,
              query TEXT, injected TEXT, trace TEXT
            );
            CREATE INDEX IF NOT EXISTS ix_chunks_event ON chunks(event_start);
            """
        )
        done = c.execute(
            "SELECT 1 FROM kv WHERE namespace='__map__' AND key='sources_done'").fetchone()
        if done is None:
            c.execute("INSERT OR IGNORE INTO memory_sources(memory_id, source, tags) "
                      "SELECT id, IFNULL(source,''), IFNULL(tags,'') FROM chunks")
            c.execute("INSERT OR REPLACE INTO kv(namespace,key,value,updated_at) "
                      "VALUES ('__map__','sources_done','1',?)", (time.time(),))
        c.commit()

    def _fts_put(self, cid, body, slots=""):
        """Index a memory's text plus its map slots ("venue: COTA · ...")."""
        if not self._has_fts:
            return
        text = body + ("\n" + slots if slots else "")
        self._conn.execute("DELETE FROM chunks_fts WHERE chunk_id=?", (cid,))
        self._conn.execute("INSERT INTO chunks_fts(chunk_id, body) VALUES (?,?)", (cid, text))

    def add_chunk(self, namespace, body, source, created_at, score, tags="",
                  embedding=None, signature=None, dim=None, source_ref="") -> str:
        namespace = namespace or GLOBAL_NS
        cid = chunk_id(namespace, source, body)
        sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
        ns_dir = self.vault_dir / sanitize_ns(namespace)
        ns_dir.mkdir(parents=True, exist_ok=True)
        path = ns_dir / f"{cid}.md"
        with self._lock:
            exists = self._conn.execute("SELECT 1 FROM chunks WHERE id=?", (cid,)).fetchone()
            if exists is None:
                content_path = str(path)
                try:
                    path.write_text(body, encoding="utf-8")
                except Exception as e:
                    logger.warning("jarvis_memory vault write failed for %s: %s", cid, e)
                    content_path = ""  # don't claim a vault file that isn't there
                now = time.time()
                self._conn.execute(
                    "INSERT INTO chunks(id,namespace,body,content_path,content_sha256,"
                    "source,created_at,score,tags,source_ref,stored_at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (cid, namespace, body, content_path, sha, source, created_at, score, tags,
                     source_ref or "", now),
                )
                self._conn.execute(
                    "INSERT OR IGNORE INTO map_queue(memory_id, queued_at) VALUES (?,?)", (cid, now))
            self._conn.execute(
                "INSERT OR IGNORE INTO memory_sources(memory_id, source, tags) VALUES (?,?,?)",
                (cid, source or "", tags or ""))
            # Keep the FTS row consistent with chunks regardless of the exists
            # guard: delete+insert repairs a missing/stale row and avoids dupes.
            slots = ""
            if exists is not None:
                row = self._conn.execute("SELECT slots FROM chunks WHERE id=?", (cid,)).fetchone()
                slots = (row["slots"] if row else "") or ""
            self._fts_put(cid, body, slots)
            if embedding is not None and len(embedding) and signature:
                self._conn.execute(
                    "INSERT OR REPLACE INTO vectors(chunk_id,namespace,embedding,model_signature,dim) "
                    "VALUES (?,?,?,?,?)",
                    (cid, namespace, _pack(embedding), signature, int(dim or len(embedding))),
                )
                self._index_put(cid, namespace, signature, embedding)
            self._conn.commit()
        return cid

    def set_vector(self, chunk_id_, namespace, embedding, signature, dim):
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO vectors(chunk_id,namespace,embedding,model_signature,dim) "
                "VALUES (?,?,?,?,?)",
                (chunk_id_, namespace or GLOBAL_NS, _pack(embedding), signature, int(dim)),
            )
            self._index_put(chunk_id_, namespace or GLOBAL_NS, signature, embedding)
            self._conn.commit()

    # -- in-memory vector index (built on first search, kept in step after) ----
    def _index_put(self, cid, namespace, signature, embedding):
        idx = self._vindex.get((namespace or GLOBAL_NS, signature))
        if idx is None:
            return
        row = self._conn.execute("SELECT status FROM chunks WHERE id=?", (cid,)).fetchone()
        if row is not None and (row["status"] or "active") != "hidden":
            idx.add(cid, embedding)

    def _index_drop(self, ids):
        for idx in self._vindex.values():
            for cid in ids:
                idx.remove(cid)

    def _index_reload(self, ids):
        """Put rows back into any built index (after they become active)."""
        if not self._vindex or not ids:
            return
        q = ",".join("?" * len(ids))
        for r in self._conn.execute(
                f"SELECT chunk_id, namespace, model_signature, embedding FROM vectors "
                f"WHERE chunk_id IN ({q})", list(ids)):
            idx = self._vindex.get((r["namespace"], r["model_signature"]))
            if idx is not None:
                idx.add(r["chunk_id"], _unpack(r["embedding"]))

    def _index_for(self, namespace, signature, dim):
        key = (namespace or GLOBAL_NS, signature)
        idx = self._vindex.get(key)
        if idx is None or idx.dim != dim:
            idx = VectorIndex(dim)
            rows = self._conn.execute(
                "SELECT v.chunk_id AS chunk_id, v.embedding AS embedding FROM vectors v "
                "JOIN chunks c ON c.id=v.chunk_id "
                f"WHERE v.namespace=? AND v.model_signature=? AND {_C_ACTIVE}",
                key,
            ).fetchall()
            idx.build((r["chunk_id"], _unpack(r["embedding"])) for r in rows)
            self._vindex[key] = idx
        return idx

    def vector_search(self, namespace, query_vec, signature, limit=20,
                      only_ids=None) -> List[Tuple[str, float]]:
        q = np.asarray(query_vec, dtype=np.float32).reshape(-1)
        with self._lock:
            idx = self._index_for(namespace, signature, q.shape[0])
            return idx.search(q, limit, only_ids=only_ids)

    def keyword_search(self, namespace, query, limit=20, only_ids=None) -> List[Tuple[str, float]]:
        ns = namespace or GLOBAL_NS
        ids: List[str] = []
        # Restricted to a candidate set, the search must not stop at the global
        # top `limit` — the candidates may all rank below it — so it reads every
        # match and filters before cutting.
        sql_limit = -1 if only_ids is not None else limit
        scores: dict = {}
        with self._lock:
            if self._has_fts:
                q = fts_query(query)
                if q:
                    try:
                        rows = self._conn.execute(
                            "SELECT f.chunk_id AS cid, bm25(chunks_fts) AS rank FROM chunks_fts f "
                            "JOIN chunks c ON c.id=f.chunk_id "
                            "WHERE c.namespace=? AND f.body MATCH ? "
                            f"AND {_C_ACTIVE} "
                            "ORDER BY rank LIMIT ?",
                            (ns, q, sql_limit),
                        ).fetchall()
                        ids = [r["cid"] for r in rows]
                        # bm25 is negative, more negative = stronger; map the
                        # strength s onto (0, 1) so a weak match scores low no
                        # matter where it lands in the list.
                        for r in rows:
                            s = max(-float(r["rank"] or 0.0), 0.0)
                            scores[r["cid"]] = s / (1.0 + s)
                    except sqlite3.OperationalError:
                        ids = []
            if only_ids is not None:
                ids = [cid for cid in ids if cid in only_ids]
            if not ids:
                toks = content_tokens(query)
                if toks:
                    like = " OR ".join(["body LIKE ?"] * len(toks))
                    args = [ns] + [f"%{t}%" for t in toks] + [sql_limit]
                    rows = self._conn.execute(
                        f"SELECT id FROM chunks WHERE namespace=? AND {_ACTIVE} AND ({like}) "
                        f"ORDER BY created_at DESC LIMIT ?",
                        args,
                    ).fetchall()
                    ids = [r["id"] for r in rows]
                    if only_ids is not None:
                        ids = [cid for cid in ids if cid in only_ids]
        return [(cid, scores.get(cid, LIKE_SCORE)) for cid in ids[:limit]]

    def get_chunks(self, ids: List[str]) -> List[Chunk]:
        if not ids:
            return []
        with self._lock:
            qmarks = ",".join("?" * len(ids))
            rows = self._conn.execute(
                f"SELECT * FROM chunks WHERE id IN ({qmarks})", list(ids)
            ).fetchall()
        by_id = {
            r["id"]: Chunk(
                id=r["id"], namespace=r["namespace"], body=r["body"],
                source=r["source"] or "", created_at=r["created_at"],
                score=r["score"] or 0.0, tags=r["tags"] or "",
                content_path=r["content_path"] or "",
                status=r["status"] or "active", event_start=r["event_start"],
                event_end=r["event_end"], valid_to=r["valid_to"],
                superseded_by=r["superseded_by"] or "", importance=r["importance"],
                kind=r["kind"] or "", pinned=int(r["pinned"] or 0), slots=r["slots"] or "",
                source_ref=r["source_ref"] or "",
            )
            for r in rows
        }
        return [by_id[i] for i in ids if i in by_id]

    def filtered_ids(self, namespace, *, source_prefix="", since=None, until=None,
                     person="", limit=200) -> List[str]:
        """Ids of memories matching every given filter, oldest first.

        ``person`` matches when each of its words appears (any order, any case)
        in the first two lines of the memory — where an iMessage or Live memory
        names who was in it. Bodies are scanned newest first and the scan stops
        at ``limit`` matches (None: all), so a person lookup stays cheap on a big store.
        """
        where, args = ["namespace=?", _ACTIVE], [namespace or GLOBAL_NS]
        if source_prefix:
            escaped = source_prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            where.append("source LIKE ? ESCAPE '\\'")
            args.append(escaped + "%")
        if since is not None:
            where.append("created_at >= ?")
            args.append(float(since))
        if until is not None:
            where.append("created_at <= ?")
            args.append(float(until))
        tokens = [t for t in re.findall(r"\w+", (person or "").lower(), flags=re.UNICODE) if t]
        cols = "id, body" if tokens else "id"
        sql = f"SELECT {cols} FROM chunks WHERE {' AND '.join(where)} ORDER BY created_at DESC"
        out: List[str] = []
        with self._lock:
            for row in self._conn.execute(sql, args):
                if tokens:
                    head = "\n".join((row["body"] or "").split("\n", 2)[:2]).lower()
                    if not all(t in head for t in tokens):
                        continue
                out.append(row["id"])
                if limit is not None and len(out) >= limit:
                    break
        out.reverse()
        return out

    def recent_chunks(self, namespace, limit=20) -> List[Chunk]:
        with self._lock:
            rows = self._conn.execute(
                f"SELECT id FROM chunks WHERE namespace=? AND {_ACTIVE} "
                "ORDER BY created_at DESC LIMIT ?",
                (namespace or GLOBAL_NS, limit),
            ).fetchall()
        return self.get_chunks([r["id"] for r in rows])

    def delete_chunk(self, cid) -> bool:
        with self._lock:
            row = self._conn.execute(
                "SELECT content_path FROM chunks WHERE id=?", (cid,)
            ).fetchone()
            cur = self._conn.execute("DELETE FROM chunks WHERE id=?", (cid,))
            self._conn.execute("DELETE FROM vectors WHERE chunk_id=?", (cid,))
            for table in ("memory_sources", "memory_entities", "map_queue"):
                self._conn.execute(f"DELETE FROM {table} WHERE memory_id=?", (cid,))
            self._index_drop([cid])
            if self._has_fts:
                self._conn.execute("DELETE FROM chunks_fts WHERE chunk_id=?", (cid,))
            self._conn.commit()
            deleted = cur.rowcount > 0
        # Remove the vault file too — "forget" must not leave plaintext on disk.
        if deleted and row and row["content_path"]:
            try:
                Path(row["content_path"]).unlink(missing_ok=True)
            except Exception as e:
                logger.warning("jarvis_memory vault unlink failed for %s: %s", cid, e)
        return deleted

    # -- sources (one memory may be backed by several) -------------------------
    def merge_source(self, memory_id, source, tags=""):
        """Link one more source to an existing memory (a near-duplicate write)."""
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO memory_sources(memory_id, source, tags) VALUES (?,?,?)",
                (memory_id, source or "", tags or ""))
            self._conn.commit()

    def forget_source(self, source_prefix="", tag="", namespace=None) -> int:
        """Unlink every source starting with ``source_prefix`` (or carrying
        ``tag``); delete each memory left with no source. Returns how many
        memories were deleted. A memory another source still backs survives."""
        if not source_prefix and not tag:
            return 0
        ns_sql = " AND c.namespace=?" if namespace else ""
        ns_arg = (namespace,) if namespace else ()
        with self._lock:
            rows = []
            if source_prefix:
                rows += self._conn.execute(
                    "SELECT s.memory_id, s.source FROM memory_sources s JOIN chunks c "
                    "ON c.id=s.memory_id WHERE s.source LIKE ? ESCAPE '\\'" + ns_sql,
                    (_like_prefix(source_prefix),) + ns_arg).fetchall()
            if tag:
                rows += self._conn.execute(
                    "SELECT s.memory_id, s.source FROM memory_sources s JOIN chunks c "
                    "ON c.id=s.memory_id WHERE (',' || s.tags || ',') LIKE ?" + ns_sql,
                    (f"%,{tag},%",) + ns_arg).fetchall()
            touched = set()
            for r in rows:
                self._conn.execute("DELETE FROM memory_sources WHERE memory_id=? AND source=?",
                                   (r["memory_id"], r["source"]))
                touched.add(r["memory_id"])
            self._conn.commit()
            orphans = [m for m in touched if self._conn.execute(
                "SELECT 1 FROM memory_sources WHERE memory_id=?", (m,)).fetchone() is None]
        return sum(1 for m in orphans if self.delete_chunk(m))

    def sources_of(self, memory_id) -> List[str]:
        with self._lock:
            return [r["source"] for r in self._conn.execute(
                "SELECT source FROM memory_sources WHERE memory_id=? ORDER BY source", (memory_id,))]

    # -- map fields -----------------------------------------------------------
    def set_status(self, ids, status):
        ids = list(ids or [])
        if not ids:
            return
        with self._lock:
            self._conn.executemany("UPDATE chunks SET status=? WHERE id=?", [(status, i) for i in ids])
            if status == "hidden":
                self._index_drop(ids)
            else:
                self._index_reload(ids)
            self._conn.commit()

    def set_map_fields(self, cid, **fields):
        bad = set(fields) - _SETTABLE
        if bad:
            raise ValueError(f"not settable: {sorted(bad)}")
        if not fields:
            return
        with self._lock:
            cols = ", ".join(f"{k}=?" for k in fields)
            self._conn.execute(f"UPDATE chunks SET {cols} WHERE id=?", list(fields.values()) + [cid])
            if "slots" in fields:
                row = self._conn.execute("SELECT body, slots FROM chunks WHERE id=?", (cid,)).fetchone()
                if row:
                    self._fts_put(cid, row["body"], row["slots"] or "")
            self._conn.commit()

    def update_body(self, cid, body, *, embedding=None, signature=None, dim=None):
        """Rewrite a memory's text in place (same id): vault, FTS and vector."""
        with self._lock:
            row = self._conn.execute(
                "SELECT namespace, content_path, slots FROM chunks WHERE id=?", (cid,)).fetchone()
            if row is None:
                return False
            sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
            self._conn.execute("UPDATE chunks SET body=?, content_sha256=? WHERE id=?", (body, sha, cid))
            self._fts_put(cid, body, row["slots"] or "")
            if embedding is not None and len(embedding) and signature:
                self._conn.execute(
                    "INSERT OR REPLACE INTO vectors(chunk_id,namespace,embedding,model_signature,dim) "
                    "VALUES (?,?,?,?,?)",
                    (cid, row["namespace"], _pack(embedding), signature, int(dim or len(embedding))))
                self._index_put(cid, row["namespace"], signature, embedding)
            self._conn.commit()
        if row["content_path"]:
            try:
                Path(row["content_path"]).write_text(body, encoding="utf-8")
            except Exception as e:
                logger.warning("jarvis_memory vault rewrite failed for %s: %s", cid, e)
        return True

    # -- map queue ------------------------------------------------------------
    def queue_ids(self, limit=50, max_attempts=3) -> List[str]:
        with self._lock:
            return [r["memory_id"] for r in self._conn.execute(
                "SELECT q.memory_id FROM map_queue q JOIN chunks c ON c.id=q.memory_id "
                f"WHERE q.attempts < ? AND {_C_ACTIVE} ORDER BY q.queued_at LIMIT ?",
                (max_attempts, limit))]

    def enqueue(self, ids):
        now = time.time()
        with self._lock:
            self._conn.executemany(
                "INSERT OR IGNORE INTO map_queue(memory_id, queued_at) VALUES (?,?)",
                [(i, now) for i in ids])
            self._conn.commit()

    def dequeue(self, ids):
        with self._lock:
            self._conn.executemany("DELETE FROM map_queue WHERE memory_id=?", [(i,) for i in ids])
            self._conn.commit()

    def bump_attempts(self, ids):
        with self._lock:
            self._conn.executemany("UPDATE map_queue SET attempts=attempts+1 WHERE memory_id=?",
                                   [(i,) for i in ids])
            self._conn.commit()

    # -- entities -------------------------------------------------------------
    def entity_version(self) -> int:
        return int(self.kv_get("__map__", "entity_version") or 0)

    def upsert_entity(self, e: dict) -> str:
        """Create or update an entity keyed by (namespace, type, canonical name);
        aliases are unioned. Returns its id."""
        ns = e.get("namespace") or GLOBAL_NS
        etype = str(e.get("type") or "topic").lower()
        canonical = " ".join(str(e.get("canonical") or "").split())
        if not canonical:
            raise ValueError("entity needs a canonical name")
        key = f"{ns}\x1e{etype}\x1e{canonical.lower()}".encode("utf-8")
        eid = "e_" + hashlib.sha256(key).hexdigest()[:20]
        aliases = [" ".join(str(a).split()) for a in (e.get("aliases") or []) if str(a).strip()]
        aliases = [a for a in aliases if a.lower() != canonical.lower()]
        with self._lock:
            row = self._conn.execute("SELECT aliases FROM entities WHERE id=?", (eid,)).fetchone()
            if row is None:
                self._conn.execute(
                    "INSERT INTO entities(id,namespace,type,canonical,aliases,summary,event_start,"
                    "event_end,pinned,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (eid, ns, etype, canonical, json.dumps(_dedup_ci(aliases)), e.get("summary") or "",
                     e.get("event_start"), e.get("event_end"), int(e.get("pinned") or 0), time.time()))
            else:
                merged = _dedup_ci(json.loads(row["aliases"] or "[]") + aliases)
                self._conn.execute(
                    "UPDATE entities SET aliases=?, summary=COALESCE(NULLIF(?,''), summary), "
                    "event_start=COALESCE(?, event_start), event_end=COALESCE(?, event_end), "
                    "updated_at=? WHERE id=?",
                    (json.dumps(merged), e.get("summary") or "", e.get("event_start"),
                     e.get("event_end"), time.time(), eid))
            cur = self._conn.execute(
                "SELECT value FROM kv WHERE namespace='__map__' AND key='entity_version'").fetchone()
            version = int(cur["value"]) if cur else 0
            self._conn.execute(
                "INSERT OR REPLACE INTO kv(namespace,key,value,updated_at) "
                "VALUES ('__map__','entity_version',?,?)", (str(version + 1), time.time()))
            self._conn.commit()
        return eid

    def link(self, memory_id, entity_id, role=""):
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO memory_entities(memory_id, entity_id, role) VALUES (?,?,?)",
                (memory_id, entity_id, role or ""))
            self._conn.commit()

    def entities_for(self, memory_ids) -> dict:
        ids = list(memory_ids or [])
        if not ids:
            return {}
        out: dict = {}
        with self._lock:
            q = ",".join("?" * len(ids))
            for r in self._conn.execute(
                    f"SELECT memory_id, entity_id, role FROM memory_entities WHERE memory_id IN ({q}) "
                    "ORDER BY memory_id, entity_id, role", ids):
                out.setdefault(r["memory_id"], []).append((r["entity_id"], r["role"]))
        return out

    def memories_for_entities(self, entity_ids, limit=50) -> List[str]:
        ids = list(entity_ids or [])
        if not ids:
            return []
        with self._lock:
            q = ",".join("?" * len(ids))
            return [r["id"] for r in self._conn.execute(
                f"SELECT c.id AS id FROM chunks c WHERE c.id IN (SELECT memory_id FROM "
                f"memory_entities WHERE entity_id IN ({q})) AND {_C_ACTIVE} "
                "ORDER BY c.created_at DESC LIMIT ?", ids + [limit])]

    def all_entities(self, namespace=None) -> List[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM entities WHERE namespace=? ORDER BY canonical",
                (namespace or GLOBAL_NS,)).fetchall()
        return [_entity_row(r) for r in rows]

    def get_entities(self, ids) -> dict:
        ids = list(ids or [])
        if not ids:
            return {}
        with self._lock:
            q = ",".join("?" * len(ids))
            rows = self._conn.execute(f"SELECT * FROM entities WHERE id IN ({q})", ids).fetchall()
        return {r["id"]: _entity_row(r) for r in rows}

    # -- recall traces --------------------------------------------------------
    def add_trace(self, session_id, query, injected, trace):
        with self._lock:
            self._conn.execute(
                "INSERT INTO recall_traces(ts, session_id, query, injected, trace) VALUES (?,?,?,?,?)",
                (time.time(), session_id or "", query or "", injected or "",
                 json.dumps(trace, default=str)))
            # Keep the table bounded: the newest 2000 turns are plenty for "why".
            self._conn.execute(
                "DELETE FROM recall_traces WHERE id <= (SELECT MAX(id) FROM recall_traces) - 2000")
            self._conn.commit()

    def recent_traces(self, n=20) -> List[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM recall_traces ORDER BY id DESC LIMIT ?", (n,)).fetchall()
        return [dict(r) | {"trace": json.loads(r["trace"] or "{}")} for r in rows]

    def count_chunks(self, namespace=None) -> int:
        with self._lock:
            if namespace is None:
                return self._conn.execute(
                    f"SELECT COUNT(*) FROM chunks WHERE {_ACTIVE}").fetchone()[0]
            return self._conn.execute(
                f"SELECT COUNT(*) FROM chunks WHERE namespace=? AND {_ACTIVE}",
                (namespace or GLOBAL_NS,)
            ).fetchone()[0]

    def namespaces(self) -> List[Tuple[str, int]]:
        """Return [(namespace, chunk_count)] descending by count (for the UI)."""
        with self._lock:
            rows = self._conn.execute(
                f"SELECT namespace, COUNT(*) AS c FROM chunks WHERE {_ACTIVE} "
                "GROUP BY namespace ORDER BY c DESC"
            ).fetchall()
        return [(r["namespace"], r["c"]) for r in rows]

    def kv_set(self, namespace, key, value):
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO kv(namespace,key,value,updated_at) VALUES (?,?,?,?)",
                (namespace or GLOBAL_NS, key, value, time.time()),
            )
            self._conn.commit()

    def kv_get(self, namespace, key) -> Optional[str]:
        with self._lock:
            r = self._conn.execute(
                "SELECT value FROM kv WHERE namespace=? AND key=?", (namespace or GLOBAL_NS, key)
            ).fetchone()
        return r["value"] if r else None

    def kv_items(self, namespace) -> List[Tuple[str, str]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT key,value FROM kv WHERE namespace=? ORDER BY updated_at DESC",
                (namespace or GLOBAL_NS,),
            ).fetchall()
        return [(r["key"], r["value"]) for r in rows]

    def kv_delete(self, namespace, key):
        with self._lock:
            self._conn.execute(
                "DELETE FROM kv WHERE namespace=? AND key=?", (namespace or GLOBAL_NS, key)
            )
            self._conn.commit()

    def close(self):
        with self._lock:
            try:
                self._conn.close()
            except Exception:
                pass
