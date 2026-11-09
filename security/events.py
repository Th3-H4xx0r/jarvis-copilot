"""Security event log: one append-only, hash-chained SQLite store per profile.

Any process (webui, gateway, cron) records an event with ``emit()``. It never
raises and never blocks: events go on a bounded queue drained by one daemon
writer thread per process. The store is WAL-mode SQLite, so several processes
append to the same file without IPC.

Tamper evidence: each row's ``hash`` covers the previous row's hash plus its own
fields (not ``outcome``, which the advisor sets later). ``verify_chain()``
returns the first row whose hash or link is wrong. Rows removed on purpose by
``prune()`` leave a recorded gap so pruning never looks like tampering.
"""
from __future__ import annotations

import hashlib
import json
import logging
import queue
import re
import sqlite3
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

DETAIL_MAX_BYTES = 4096
QUEUE_MAX = 5000

_SECRET_KEY = re.compile(
    r"password|passwd|secret|token|api_key|apikey|cookie|authorization|signature", re.I)
_BEARER = re.compile(r"Bearer\s+\S+", re.I)
_SK_KEY = re.compile(r"sk-[A-Za-z0-9_-]+")
REDACTED = "[redacted]"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(detail: dict) -> dict:
    """A copy of ``detail`` with secret-looking keys and inline tokens removed."""
    def walk(value, key=""):
        if key and _SECRET_KEY.search(key):
            return REDACTED
        if isinstance(value, dict):
            return {str(k): walk(v, str(k)) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [walk(v) for v in value]
        if isinstance(value, str):
            return _SK_KEY.sub(REDACTED, _BEARER.sub("Bearer " + REDACTED, value))
        if value is None or isinstance(value, (bool, int, float)):
            return value
        return walk(str(value))
    return walk(detail or {})


def _dump(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str)


def _cap(detail: dict) -> dict:
    text = _dump(detail)
    if len(text) <= DETAIL_MAX_BYTES:
        return detail
    return {"truncated": True, "preview": text[: DETAIL_MAX_BYTES - 64]}


def _row_hash(prev_hash: str, ts: str, source: str, kind: str, actor_json: str,
              detail_json: str) -> str:
    h = hashlib.sha256()
    for part in (prev_hash, ts, source, kind, actor_json, detail_json):
        h.update(part.encode("utf-8"))
        h.update(b"\x1f")
    return h.hexdigest()


@dataclass
class Event:
    id: int
    ts: str
    source: str
    kind: str
    actor: dict = field(default_factory=dict)
    detail: dict = field(default_factory=dict)
    outcome: str = ""
    hash: str = ""

    def to_dict(self) -> dict:
        return {"id": self.id, "ts": self.ts, "source": self.source, "kind": self.kind,
                "actor": self.actor, "detail": self.detail, "outcome": self.outcome}


_SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    actor TEXT NOT NULL,
    detail TEXT NOT NULL,
    outcome TEXT NOT NULL DEFAULT '',
    note TEXT NOT NULL DEFAULT '',
    prev_hash TEXT NOT NULL,
    hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_kind_ts ON events(kind, ts);
CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
CREATE TABLE IF NOT EXISTS chain_gaps (row_id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL,
    rule TEXT NOT NULL,
    title TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    explanation TEXT NOT NULL DEFAULT '',
    severity TEXT NOT NULL DEFAULT 'medium',
    dedup_key TEXT NOT NULL DEFAULT '',
    count INTEGER NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'open',
    resolved_by TEXT NOT NULL DEFAULT '',
    created TEXT NOT NULL,
    updated TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS alerts_key ON alerts(dedup_key, updated);
CREATE TABLE IF NOT EXISTS digests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day TEXT NOT NULL,
    created TEXT NOT NULL,
    text TEXT NOT NULL,
    data TEXT NOT NULL
);
"""

SEVERITIES = ("low", "medium", "high", "critical")
ALERT_STATUSES = ("open", "blocked", "allowed", "dismissed")


class EventLog:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), timeout=10, check_same_thread=False,
                                     isolation_level=None)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA busy_timeout=10000")
        self._conn.executescript(_SCHEMA)
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    # ── writes ────────────────────────────────────────────────────────────
    def append(self, source: str, kind: str, actor: dict | None, detail: dict | None,
               ts: str | None = None) -> Event:
        ts = ts or utc_now()
        actor = redact(actor or {})
        detail = _cap(redact(detail or {}))
        actor_json, detail_json = _dump(actor), _dump(detail)
        with self._lock:
            # BEGIN IMMEDIATE serialises appends across processes, so the chain
            # always links to the true last row.
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                row = self._conn.execute(
                    "SELECT hash FROM events ORDER BY id DESC LIMIT 1").fetchone()
                prev = row[0] if row else ""
                digest = _row_hash(prev, ts, source, kind, actor_json, detail_json)
                cur = self._conn.execute(
                    "INSERT INTO events (ts, source, kind, actor, detail, prev_hash, hash) "
                    "VALUES (?,?,?,?,?,?,?)",
                    (ts, source, kind, actor_json, detail_json, prev, digest))
                self._conn.execute("COMMIT")
            except Exception:
                self._conn.execute("ROLLBACK")
                raise
        return Event(cur.lastrowid, ts, source, kind, actor, detail, "", digest)

    def set_outcome(self, event_id: int, outcome: str, note: str = "") -> None:
        with self._lock:
            self._conn.execute("UPDATE events SET outcome=?, note=? WHERE id=?",
                               (outcome, note, int(event_id)))

    # ── reads ─────────────────────────────────────────────────────────────
    @staticmethod
    def _event(row) -> Event:
        def load(text):
            try:
                return json.loads(text)
            except Exception:
                return {}
        return Event(row[0], row[1], row[2], row[3], load(row[4]), load(row[5]), row[6], row[7])

    def query(self, since: str | None = None, kinds: list[str] | None = None,
              outcome: str | None = None, limit: int = 200, after_id: int = 0) -> list[Event]:
        """Matching events. With ``after_id`` > 0 they come oldest first (a cursor);
        otherwise the newest ``limit`` come newest first (a feed)."""
        where, args = [], []
        if since:
            where.append("ts >= ?"); args.append(since)
        if kinds:
            where.append(f"kind IN ({','.join('?' * len(kinds))})"); args.extend(kinds)
        if outcome is not None:
            where.append("outcome = ?"); args.append(outcome)
        if after_id:
            where.append("id > ?"); args.append(int(after_id))
        sql = "SELECT id, ts, source, kind, actor, detail, outcome, hash FROM events"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY id " + ("ASC" if after_id else "DESC") + " LIMIT ?"
        args.append(max(1, int(limit)))
        with self._lock:
            rows = self._conn.execute(sql, args).fetchall()
        return [self._event(r) for r in rows]

    def last_id(self) -> int:
        with self._lock:
            row = self._conn.execute("SELECT MAX(id) FROM events").fetchone()
        return int(row[0] or 0)

    def verify_chain(self) -> int | None:
        """The id of the first row whose hash or link is wrong; None if intact."""
        with self._lock:
            gaps = {r[0] for r in self._conn.execute("SELECT row_id FROM chain_gaps")}
            rows = self._conn.execute(
                "SELECT id, ts, source, kind, actor, detail, prev_hash, hash "
                "FROM events ORDER BY id").fetchall()
        prev = ""
        for rid, ts, source, kind, actor, detail, prev_hash, digest in rows:
            if prev_hash != prev and rid not in gaps:
                return rid
            if _row_hash(prev_hash, ts, source, kind, actor, detail) != digest:
                return rid
            prev = digest
        return None

    def prune(self, digest_days: int = 90) -> int:
        """Delete digest/ignore events older than ``digest_days``. Alerts and blocks stay."""
        cutoff = (datetime.now(timezone.utc) - timedelta(days=digest_days)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                doomed = {r[0] for r in self._conn.execute(
                    "SELECT id FROM events WHERE ts < ? AND outcome IN ('digest','ignore')",
                    (cutoff,))}
                if doomed:
                    # Each surviving row right after a deleted one is a sanctioned gap.
                    for rid in doomed:
                        nxt = self._conn.execute(
                            "SELECT MIN(id) FROM events WHERE id > ?", (rid,)).fetchone()[0]
                        if nxt is not None and nxt not in doomed:
                            self._conn.execute(
                                "INSERT OR IGNORE INTO chain_gaps (row_id) VALUES (?)", (nxt,))
                    self._conn.executemany("DELETE FROM events WHERE id=?",
                                           [(r,) for r in doomed])
                self._conn.execute("COMMIT")
            except Exception:
                self._conn.execute("ROLLBACK")
                raise
        return len(doomed)

    # ── alerts ────────────────────────────────────────────────────────────
    _ALERT_COLS = ("a.id, a.event_id, a.rule, a.title, a.summary, a.explanation, a.severity, "
                   "a.dedup_key, a.count, a.status, a.resolved_by, a.created, a.updated, "
                   "e.kind, e.actor, e.source")

    def _alert_dict(self, row) -> dict:
        keys = ("id", "event_id", "rule", "title", "summary", "explanation", "severity",
                "dedup_key", "count", "status", "resolved_by", "created", "updated", "kind")
        out = dict(zip(keys, row[:14]))
        try:
            out["actor"] = json.loads(row[14]) if row[14] else {}
        except ValueError:
            out["actor"] = {}
        out["source"] = row[15] or ""
        return out

    def add_alert(self, event_id: int, decision, explanation: str = "") -> int:
        """Record an alert for a rule decision. A ``block`` decision is stored as ``blocked``."""
        now = utc_now()
        status = "blocked" if decision.outcome == "block" else "open"
        severity = "high" if decision.outcome == "block" else "medium"
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO alerts (event_id, rule, title, summary, explanation, severity, "
                "dedup_key, status, created, updated) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (int(event_id), decision.rule, decision.title, decision.summary,
                 explanation or "", severity, decision.dedup_key, status, now, now))
        return int(cur.lastrowid)

    def bump_alert(self, dedup_key: str, within_s: int) -> int | None:
        """If an open (or auto-blocked) alert with this key was updated in the last
        ``within_s`` seconds, add one to its count and return its id."""
        cutoff = (datetime.now(timezone.utc) - timedelta(seconds=within_s)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        with self._lock:
            row = self._conn.execute(
                "SELECT id FROM alerts WHERE dedup_key=? AND status IN ('open','blocked') "
                "AND updated >= ? ORDER BY id DESC LIMIT 1", (dedup_key, cutoff)).fetchone()
            if row is None:
                return None
            self._conn.execute("UPDATE alerts SET count=count+1, updated=? WHERE id=?",
                               (utc_now(), row[0]))
        return int(row[0])

    def get_alert(self, alert_id: int) -> dict | None:
        with self._lock:
            row = self._conn.execute(
                f"SELECT {self._ALERT_COLS} FROM alerts a LEFT JOIN events e ON e.id=a.event_id "
                "WHERE a.id=?", (int(alert_id),)).fetchone()
        return self._alert_dict(row) if row else None

    def list_alerts(self, status: str | None = None, limit: int = 100) -> list[dict]:
        sql = f"SELECT {self._ALERT_COLS} FROM alerts a LEFT JOIN events e ON e.id=a.event_id"
        args: list = []
        if status:
            sql += " WHERE a.status=?"
            args.append(status)
        sql += " ORDER BY a.id DESC LIMIT ?"
        args.append(max(1, int(limit)))
        with self._lock:
            rows = self._conn.execute(sql, args).fetchall()
        return [self._alert_dict(r) for r in rows]

    def resolve_alert(self, alert_id: int, status: str, by: str) -> dict:
        if status not in ("blocked", "allowed", "dismissed"):
            raise ValueError("status must be blocked, allowed or dismissed")
        with self._lock:
            self._conn.execute("UPDATE alerts SET status=?, resolved_by=?, updated=? WHERE id=?",
                               (status, str(by or ""), utc_now(), int(alert_id)))
        alert = self.get_alert(alert_id)
        if alert is None:
            raise KeyError(alert_id)
        return alert

    def set_explanation(self, alert_id: int, text: str, severity: str) -> None:
        if severity not in SEVERITIES:
            severity = "medium"
        with self._lock:
            self._conn.execute("UPDATE alerts SET explanation=?, severity=? WHERE id=?",
                               (str(text or "")[:2000], severity, int(alert_id)))

    # ── digests ───────────────────────────────────────────────────────────
    def add_digest(self, day: str, text: str, data: dict) -> int:
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO digests (day, created, text, data) VALUES (?,?,?,?)",
                (day, utc_now(), text, _dump(data)))
        return int(cur.lastrowid)

    def list_digests(self, limit: int = 30) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT id, day, created, text, data FROM digests ORDER BY id DESC LIMIT ?",
                (max(1, int(limit)),)).fetchall()
        out = []
        for rid, day, created, text, data in rows:
            try:
                parsed = json.loads(data)
            except ValueError:
                parsed = {}
            out.append({"id": rid, "day": day, "created": created, "text": text, "data": parsed})
        return out

    def close(self) -> None:
        with self._lock:
            self._conn.close()


# ── shared default log + non-blocking emit ────────────────────────────────

_logs: dict[str, EventLog] = {}
_logs_lock = threading.Lock()


def default_log() -> EventLog:
    """The profile's event log at ``get_hermes_home()/security/events.db``."""
    from jarviscopilot_constants import get_hermes_home
    path = get_hermes_home() / "security" / "events.db"
    key = str(path)
    with _logs_lock:
        log = _logs.get(key)
        if log is None:
            log = _logs[key] = EventLog(path)
        return log


_queue: "queue.Queue[tuple]" = queue.Queue(maxsize=QUEUE_MAX)
_writer: threading.Thread | None = None
_writer_lock = threading.Lock()
_dropped = 0


def _write_one(item: tuple) -> None:
    source, kind, actor, detail, ts = item
    default_log().append(source, kind, actor, detail, ts=ts)


def _drain() -> None:
    global _dropped
    while True:
        item = _queue.get()
        try:
            _write_one(item)
            if _dropped:
                count, _dropped = _dropped, 0
                _write_one(("host", "security.dropped", {}, {"count": count}, utc_now()))
        except Exception as e:  # a full disk must not kill the writer
            logger.debug("security event write failed: %s", e)
        finally:
            _queue.task_done()


def _ensure_writer() -> None:
    global _writer
    if _writer is not None and _writer.is_alive():
        return
    with _writer_lock:
        if _writer is None or not _writer.is_alive():
            _writer = threading.Thread(target=_drain, name="security-events", daemon=True)
            _writer.start()


def emit(source: str, kind: str, actor: dict | None = None, /, **detail) -> None:
    """Record a security event. Never raises, never blocks."""
    global _dropped
    try:
        _ensure_writer()
        _queue.put_nowait((source, kind, dict(actor or {}), detail, utc_now()))
    except queue.Full:
        _dropped += 1
    except Exception as e:
        logger.debug("security emit failed: %s", e)


def flush(timeout: float = 2.0) -> None:
    """Wait (up to ``timeout``) for queued events to be written. For tests and shutdown."""
    deadline = time.monotonic() + timeout
    while _queue.unfinished_tasks and time.monotonic() < deadline:
        time.sleep(0.005)
