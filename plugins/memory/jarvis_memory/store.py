"""SQLite + markdown-vault storage for jarvis_memory.

The markdown vault under ``<vault_dir>/<namespace>/<id>.md`` is the durable
source of truth for each chunk body; SQLite holds the index, metadata, vectors
(brute-force cosine), an FTS5 keyword index, and a key-value store. This is the
only module that touches SQLite.
"""
from __future__ import annotations

import hashlib
import logging
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

import numpy as np

logger = logging.getLogger(__name__)
GLOBAL_NS = "global"


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


def _fts_or_query(query: str) -> str:
    # \w is Unicode-aware in Python 3 — keep accented/CJK tokens (the FTS table
    # uses unicode61, which indexes them). Quoting neutralizes FTS operators.
    toks = re.findall(r"\w+", query or "", flags=re.UNICODE)
    return " OR ".join(f'"{t}"' for t in toks)


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

    def add_chunk(self, namespace, body, source, created_at, score, tags="",
                  embedding=None, signature=None, dim=None) -> str:
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
                self._conn.execute(
                    "INSERT INTO chunks(id,namespace,body,content_path,content_sha256,"
                    "source,created_at,score,tags) VALUES (?,?,?,?,?,?,?,?,?)",
                    (cid, namespace, body, content_path, sha, source, created_at, score, tags),
                )
            # Keep the FTS row consistent with chunks regardless of the exists
            # guard: delete+insert repairs a missing/stale row and avoids dupes.
            if self._has_fts:
                self._conn.execute("DELETE FROM chunks_fts WHERE chunk_id=?", (cid,))
                self._conn.execute(
                    "INSERT INTO chunks_fts(chunk_id, body) VALUES (?,?)", (cid, body)
                )
            if embedding is not None and len(embedding) and signature:
                self._conn.execute(
                    "INSERT OR REPLACE INTO vectors(chunk_id,namespace,embedding,model_signature,dim) "
                    "VALUES (?,?,?,?,?)",
                    (cid, namespace, _pack(embedding), signature, int(dim or len(embedding))),
                )
            self._conn.commit()
        return cid

    def set_vector(self, chunk_id_, namespace, embedding, signature, dim):
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO vectors(chunk_id,namespace,embedding,model_signature,dim) "
                "VALUES (?,?,?,?,?)",
                (chunk_id_, namespace or GLOBAL_NS, _pack(embedding), signature, int(dim)),
            )
            self._conn.commit()

    def vector_search(self, namespace, query_vec, signature, limit=20) -> List[Tuple[str, float]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT chunk_id, embedding FROM vectors WHERE namespace=? AND model_signature=?",
                (namespace or GLOBAL_NS, signature),
            ).fetchall()
        if not rows:
            return []
        q = np.asarray(query_vec, dtype=np.float32)
        qn = float(np.linalg.norm(q)) or 1.0
        scored: List[Tuple[str, float]] = []
        for r in rows:
            v = _unpack(r["embedding"])
            if v.shape[0] != q.shape[0]:
                continue
            vn = float(np.linalg.norm(v)) or 1.0
            scored.append((r["chunk_id"], float(np.dot(q, v) / (qn * vn))))
        scored.sort(key=lambda x: x[1], reverse=True)
        return scored[:limit]

    def keyword_search(self, namespace, query, limit=20) -> List[Tuple[str, float]]:
        ns = namespace or GLOBAL_NS
        ids: List[str] = []
        with self._lock:
            if self._has_fts:
                q = _fts_or_query(query)
                if q:
                    try:
                        rows = self._conn.execute(
                            "SELECT f.chunk_id AS cid FROM chunks_fts f "
                            "JOIN chunks c ON c.id=f.chunk_id "
                            "WHERE c.namespace=? AND f.body MATCH ? "
                            "ORDER BY bm25(chunks_fts) LIMIT ?",
                            (ns, q, limit),
                        ).fetchall()
                        ids = [r["cid"] for r in rows]
                    except sqlite3.OperationalError:
                        ids = []
            if not ids:
                toks = re.findall(r"\w+", query or "", flags=re.UNICODE)
                if toks:
                    like = " OR ".join(["body LIKE ?"] * len(toks))
                    args = [ns] + [f"%{t}%" for t in toks] + [limit]
                    rows = self._conn.execute(
                        f"SELECT id FROM chunks WHERE namespace=? AND ({like}) "
                        f"ORDER BY created_at DESC LIMIT ?",
                        args,
                    ).fetchall()
                    ids = [r["id"] for r in rows]
        n = len(ids)
        return [(cid, (n - i) / n) for i, cid in enumerate(ids)] if n else []

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
            )
            for r in rows
        }
        return [by_id[i] for i in ids if i in by_id]

    def recent_chunks(self, namespace, limit=20) -> List[Chunk]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT id FROM chunks WHERE namespace=? ORDER BY created_at DESC LIMIT ?",
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

    def count_chunks(self, namespace=None) -> int:
        with self._lock:
            if namespace is None:
                return self._conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
            return self._conn.execute(
                "SELECT COUNT(*) FROM chunks WHERE namespace=?", (namespace or GLOBAL_NS,)
            ).fetchone()[0]

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
