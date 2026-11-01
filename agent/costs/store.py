"""SQLite store behind Cost Insights: daily amounts, balance snapshots, the local meter.

One file per profile (``<home>/costs.db``). Every daily amount carries a ``source``:
``billing`` (the provider's own billing API), ``estimate`` (Jarvis's count × list price) or
``subscription`` (a plan price spread over its days). Rows are upserted, so the collector can
recompute recent days on every run while older days stay as they were — that is what keeps
history after ``state.db`` is pruned or a provider's billing window rolls off.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

SOURCES = ("billing", "estimate", "subscription")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS services (
    id TEXT PRIMARY KEY,
    config_json TEXT NOT NULL DEFAULT '{}',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS daily (
    service TEXT NOT NULL,
    day TEXT NOT NULL,
    source TEXT NOT NULL,
    amount_usd REAL NOT NULL DEFAULT 0,
    units_json TEXT,
    updated_at REAL NOT NULL,
    PRIMARY KEY (service, day, source)
);
CREATE INDEX IF NOT EXISTS idx_daily_day ON daily(day);
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service TEXT NOT NULL,
    ts REAL NOT NULL,
    balance_usd REAL,
    used_usd REAL,
    limit_usd REAL,
    raw_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_snapshots_service ON snapshots(service, ts);
CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    service TEXT NOT NULL,
    kind TEXT NOT NULL,
    units REAL NOT NULL DEFAULT 0,
    meta_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_usage_events_service ON usage_events(service, ts);
CREATE TABLE IF NOT EXISTS sync_state (
    service TEXT PRIMARY KEY,
    last_attempt_ts REAL,
    last_ok_ts REAL,
    last_error TEXT
);
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""


def default_path() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home() / "costs.db"


def _tz():
    try:
        from jarviscopilot_time import get_timezone
        return get_timezone()
    except Exception:
        return None


def day_of(ts: float) -> str:
    """The calendar day (``YYYY-MM-DD``) a timestamp falls on, in the user's timezone."""
    tz = _tz()
    dt = datetime.fromtimestamp(ts, tz) if tz else datetime.fromtimestamp(ts)
    return dt.strftime("%Y-%m-%d")


def day_start_ts(day: str) -> float:
    """Epoch seconds of local midnight that starts ``day``."""
    tz = _tz()
    dt = datetime.strptime(day, "%Y-%m-%d")
    if tz:
        dt = dt.replace(tzinfo=tz)
    return dt.timestamp()


def days_back(n: int, *, now: Optional[float] = None) -> List[str]:
    """The last ``n`` calendar days, oldest first, ending today."""
    ts = time.time() if now is None else now
    out: List[str] = []
    for i in range(n - 1, -1, -1):
        d = day_of(ts - i * 86400)
        if not out or out[-1] != d:
            out.append(d)
    return out


class CostStore:
    def __init__(self, path: Optional[Path] = None) -> None:
        self.path = Path(path) if path else default_path()
        self._lock = threading.RLock()
        self._conn: Optional[sqlite3.Connection] = None

    def _db(self) -> sqlite3.Connection:
        if self._conn is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(str(self.path), timeout=10, check_same_thread=False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.executescript(_SCHEMA)
            self._conn = conn
        return self._conn

    def close(self) -> None:
        with self._lock:
            if self._conn is not None:
                self._conn.close()
                self._conn = None

    # ── daily ────────────────────────────────────────────────────────────
    def upsert_daily(self, service: str, day: str, source: str, amount_usd: float,
                     units: Optional[Dict[str, Any]] = None) -> None:
        if source not in SOURCES:
            raise ValueError(f"unknown source {source!r}")
        with self._lock:
            db = self._db()
            db.execute(
                "INSERT INTO daily (service, day, source, amount_usd, units_json, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(service, day, source) DO UPDATE SET "
                "amount_usd=excluded.amount_usd, units_json=excluded.units_json, "
                "updated_at=excluded.updated_at",
                (service, day, source, float(amount_usd or 0),
                 json.dumps(units, sort_keys=True) if units else None, time.time()))
            db.commit()

    def delete_daily(self, service: str, source: str, since_day: Optional[str] = None) -> None:
        with self._lock:
            db = self._db()
            if since_day:
                db.execute("DELETE FROM daily WHERE service=? AND source=? AND day>=?",
                           (service, source, since_day))
            else:
                db.execute("DELETE FROM daily WHERE service=? AND source=?", (service, source))
            db.commit()

    def daily_rows(self, since_day: str, until_day: Optional[str] = None,
                   service: Optional[str] = None) -> List[Dict[str, Any]]:
        sql = "SELECT service, day, source, amount_usd, units_json FROM daily WHERE day>=?"
        args: List[Any] = [since_day]
        if until_day:
            sql += " AND day<=?"
            args.append(until_day)
        if service:
            sql += " AND service=?"
            args.append(service)
        sql += " ORDER BY day"
        with self._lock:
            rows = self._db().execute(sql, args).fetchall()
        return [{
            "service": r["service"], "day": r["day"], "source": r["source"],
            "amount_usd": float(r["amount_usd"] or 0),
            "units": json.loads(r["units_json"]) if r["units_json"] else {},
        } for r in rows]

    def earliest_day(self, source: Optional[str] = None) -> Optional[str]:
        sql, args = "SELECT MIN(day) FROM daily", []
        if source:
            sql += " WHERE source=?"
            args.append(source)
        with self._lock:
            row = self._db().execute(sql, args).fetchone()
        return row[0] if row and row[0] else None

    def services_with_rows(self) -> List[str]:
        with self._lock:
            rows = self._db().execute("SELECT DISTINCT service FROM daily").fetchall()
        return [r[0] for r in rows]

    # ── snapshots ────────────────────────────────────────────────────────
    def add_snapshot(self, service: str, *, balance_usd: Optional[float] = None,
                     used_usd: Optional[float] = None, limit_usd: Optional[float] = None,
                     raw: Optional[Dict[str, Any]] = None, ts: Optional[float] = None) -> None:
        with self._lock:
            db = self._db()
            db.execute(
                "INSERT INTO snapshots (service, ts, balance_usd, used_usd, limit_usd, raw_json) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (service, ts if ts is not None else time.time(), balance_usd, used_usd, limit_usd,
                 json.dumps(raw)[:20000] if raw else None))
            db.commit()

    def snapshots(self, service: str, since_ts: float = 0) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._db().execute(
                "SELECT ts, balance_usd, used_usd, limit_usd FROM snapshots "
                "WHERE service=? AND ts>=? ORDER BY ts", (service, since_ts)).fetchall()
        return [dict(r) for r in rows]

    def last_snapshot(self, service: str, before_ts: Optional[float] = None) -> Optional[Dict[str, Any]]:
        sql = "SELECT ts, balance_usd, used_usd, limit_usd FROM snapshots WHERE service=?"
        args: List[Any] = [service]
        if before_ts is not None:
            sql += " AND ts<?"
            args.append(before_ts)
        sql += " ORDER BY ts DESC LIMIT 1"
        with self._lock:
            row = self._db().execute(sql, args).fetchone()
        return dict(row) if row else None

    # ── local meter ──────────────────────────────────────────────────────
    def record_event(self, service: str, kind: str, units: float,
                     meta: Optional[Dict[str, Any]] = None, ts: Optional[float] = None) -> None:
        with self._lock:
            db = self._db()
            db.execute(
                "INSERT INTO usage_events (ts, service, kind, units, meta_json) VALUES (?, ?, ?, ?, ?)",
                (ts if ts is not None else time.time(), service, kind, float(units or 0),
                 json.dumps(meta, sort_keys=True) if meta else None))
            db.commit()

    def events(self, service: str, since_ts: float = 0) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._db().execute(
                "SELECT ts, kind, units, meta_json FROM usage_events WHERE service=? AND ts>=? "
                "ORDER BY ts", (service, since_ts)).fetchall()
        return [{"ts": r["ts"], "kind": r["kind"], "units": float(r["units"] or 0),
                 "meta": json.loads(r["meta_json"]) if r["meta_json"] else {}} for r in rows]

    # ── service config (non-secret) ──────────────────────────────────────
    def service_config(self, service: str) -> Dict[str, Any]:
        return self.all_service_configs().get(service, {})

    def all_service_configs(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            rows = self._db().execute("SELECT id, config_json FROM services").fetchall()
        out: Dict[str, Dict[str, Any]] = {}
        for r in rows:
            try:
                data = json.loads(r["config_json"] or "{}")
            except ValueError:
                data = {}
            out[r["id"]] = data if isinstance(data, dict) else {}
        return out

    def set_service_config(self, service: str, config: Dict[str, Any]) -> None:
        now = time.time()
        with self._lock:
            db = self._db()
            db.execute(
                "INSERT INTO services (id, config_json, created_at, updated_at) VALUES (?, ?, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET config_json=excluded.config_json, "
                "updated_at=excluded.updated_at",
                (service, json.dumps(config, sort_keys=True), now, now))
            db.commit()

    def delete_service_config(self, service: str) -> None:
        with self._lock:
            db = self._db()
            db.execute("DELETE FROM services WHERE id=?", (service,))
            db.commit()

    # ── sync state ───────────────────────────────────────────────────────
    def mark_sync(self, service: str, *, ok: bool, error: Optional[str] = None) -> None:
        now = time.time()
        with self._lock:
            db = self._db()
            if ok:
                db.execute(
                    "INSERT INTO sync_state (service, last_attempt_ts, last_ok_ts, last_error) "
                    "VALUES (?, ?, ?, NULL) ON CONFLICT(service) DO UPDATE SET "
                    "last_attempt_ts=excluded.last_attempt_ts, last_ok_ts=excluded.last_ok_ts, "
                    "last_error=NULL", (service, now, now))
            else:
                db.execute(
                    "INSERT INTO sync_state (service, last_attempt_ts, last_error) VALUES (?, ?, ?) "
                    "ON CONFLICT(service) DO UPDATE SET last_attempt_ts=excluded.last_attempt_ts, "
                    "last_error=excluded.last_error", (service, now, (error or "failed")[:500]))
            db.commit()

    def sync_states(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            rows = self._db().execute("SELECT * FROM sync_state").fetchall()
        return {r["service"]: dict(r) for r in rows}

    def clear_sync(self, service: str) -> None:
        with self._lock:
            db = self._db()
            db.execute("DELETE FROM sync_state WHERE service=?", (service,))
            db.commit()

    # ── meta ─────────────────────────────────────────────────────────────
    def get_meta(self, key: str) -> Optional[str]:
        with self._lock:
            row = self._db().execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key: str, value: Optional[str]) -> None:
        with self._lock:
            db = self._db()
            if value is None:
                db.execute("DELETE FROM meta WHERE key=?", (key,))
            else:
                db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) "
                           "DO UPDATE SET value=excluded.value", (key, value))
            db.commit()


_STORE: Optional[CostStore] = None
_STORE_LOCK = threading.Lock()


def get_store() -> CostStore:
    """The process-wide store for the active profile (re-opened if the home moved)."""
    global _STORE
    with _STORE_LOCK:
        path = default_path()
        if _STORE is None or _STORE.path != path:
            if _STORE is not None:
                _STORE.close()
            _STORE = CostStore(path)
        return _STORE
