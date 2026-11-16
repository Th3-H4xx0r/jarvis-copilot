"""PC Stats history and dashboards (SQLite under the Jarvis home).

Samples arrive at 1 Hz (live) or as 10-second averages; each is folded into three tables of
buckets — 10 s (kept 7 days), 1 min (90 days), 1 h (forever) — holding avg/min/max per reading.
History reads come from the finest table that still covers the range. Game sessions, marked
moments and dashboards are kept forever. Dashboards carry a revision: a write with a stale
revision is refused, so two devices editing at once can't silently overwrite each other.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from contextlib import closing
from pathlib import Path
from typing import Callable, Optional

from api.pc_stats_catalog import default_dashboards, reading_info, validate_dashboard

TABLES = (("s10", 10, 7 * 86400), ("m1", 60, 90 * 86400), ("h1", 3600, None))


class Conflict(Exception):
    def __init__(self, current: dict):
        super().__init__("changed elsewhere")
        self.current = current


class PcStatsStore:
    def __init__(self, root: Path, clock: Callable[[], float] = time.time):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._db = self.root / "pc_stats.db"
        self.clock = clock
        self._lock = threading.Lock()
        with closing(self._conn()) as db, db:
            for name, _, _ in TABLES:
                db.execute(f"CREATE TABLE IF NOT EXISTS {name} (device TEXT, key TEXT, t INTEGER, n INTEGER,"
                           f" sum REAL, min REAL, max REAL, PRIMARY KEY (device, key, t))")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS latest (device TEXT PRIMARY KEY, t REAL, data TEXT);
                CREATE TABLE IF NOT EXISTS sessions (device TEXT, id TEXT, start REAL, data TEXT, PRIMARY KEY (device, id));
                CREATE TABLE IF NOT EXISTS moments (device TEXT, id TEXT, t REAL, data TEXT, PRIMARY KEY (device, id));
                CREATE TABLE IF NOT EXISTS dashboards (id TEXT PRIMARY KEY, rev INTEGER, pos INTEGER, data TEXT);
                CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
            """)

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self._db), timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    # ── samples ──────────────────────────────────────────────────────────
    def ingest(self, device_id: str, samples: list, estimated: list) -> int:
        """Folds samples into the three bucket tables; unknown readings are dropped. Returns how
        many samples were kept."""
        kept = 0
        newest: Optional[dict] = None
        with self._lock, closing(self._conn()) as db, db:
            for s in samples or []:
                if not isinstance(s, dict) or not isinstance(s.get("r"), dict):
                    continue
                try:
                    t = float(s.get("t"))
                except (TypeError, ValueError):
                    continue
                values = {k: float(v) for k, v in s["r"].items()
                          if reading_info(k) is not None and isinstance(v, (int, float)) and v == v}
                if not values:
                    continue
                kept += 1
                for name, step, _ in TABLES:
                    bucket = int(t // step * step)
                    for k, v in values.items():
                        db.execute(
                            f"INSERT INTO {name} (device, key, t, n, sum, min, max) VALUES (?,?,?,1,?,?,?)"
                            f" ON CONFLICT(device, key, t) DO UPDATE SET n=n+1, sum=sum+excluded.sum,"
                            f" min=MIN(min, excluded.min), max=MAX(max, excluded.max)",
                            (device_id, k, bucket, v, v, v))
                if newest is None or t >= newest["t"]:
                    newest = {"t": t, "r": values, "game": s.get("game")}
            if newest is not None:
                newest["estimated"] = [k for k in (estimated or []) if isinstance(k, str)]
                row = db.execute("SELECT t FROM latest WHERE device=?", (device_id,)).fetchone()
                if row is None or newest["t"] >= row["t"]:
                    db.execute("INSERT OR REPLACE INTO latest (device, t, data) VALUES (?,?,?)",
                               (device_id, newest["t"], json.dumps(newest)))
        return kept

    def latest(self, device_id: str) -> Optional[dict]:
        with closing(self._conn()) as db:
            row = db.execute("SELECT data FROM latest WHERE device=?", (device_id,)).fetchone()
        return json.loads(row["data"]) if row else None

    def devices(self) -> list[dict]:
        """Every reporting device, newest first: [{device_id, t}]."""
        with closing(self._conn()) as db:
            rows = db.execute("SELECT device, t FROM latest ORDER BY t DESC").fetchall()
        return [{"device_id": r["device"], "t": r["t"]} for r in rows]

    def history(self, device_id: str, key: str, t0: float, t1: float, points: int = 300) -> list:
        """[[t, avg, min, max], …] from the finest table whose retention covers t0, merged down
        to at most `points` points."""
        now = self.clock()
        name, step = "h1", 3600
        for tname, tstep, keep in TABLES:
            if keep is None or t0 >= now - keep:
                name, step = tname, tstep
                break
        with closing(self._conn()) as db:
            rows = db.execute(f"SELECT t, n, sum, min, max FROM {name} WHERE device=? AND key=? AND t>=? AND t<=?"
                              f" ORDER BY t", (device_id, key, int(t0 // step * step), t1)).fetchall()
        points = max(1, min(int(points or 300), 2000))
        span = max(step, (t1 - t0) / points)
        out: list = []
        group: list = []
        for r in rows:
            if group and r["t"] - group[0]["t"] >= span:
                out.append(_merge(group))
                group = []
            group.append(r)
        if group:
            out.append(_merge(group))
        return out

    def prune(self, now: Optional[float] = None) -> None:
        now = self.clock() if now is None else now
        with self._lock, closing(self._conn()) as db, db:
            for name, _, keep in TABLES:
                if keep is not None:
                    db.execute(f"DELETE FROM {name} WHERE t < ?", (now - keep,))

    # ── sessions & moments ───────────────────────────────────────────────
    def add_sessions(self, device_id: str, sessions: list) -> None:
        self._put_rows("sessions", "start", device_id, sessions)

    def sessions(self, device_id: str, limit: int = 50) -> list:
        with closing(self._conn()) as db:
            rows = db.execute("SELECT data FROM sessions WHERE device=? ORDER BY start DESC LIMIT ?",
                              (device_id, max(1, min(int(limit), 500)))).fetchall()
        return [json.loads(r["data"]) for r in rows]

    def add_moments(self, device_id: str, moments: list) -> None:
        self._put_rows("moments", "t", device_id, moments)

    def moments(self, device_id: str, t0: float, t1: float) -> list:
        with closing(self._conn()) as db:
            rows = db.execute("SELECT data FROM moments WHERE device=? AND t>=? AND t<=? ORDER BY t",
                              (device_id, t0, t1)).fetchall()
        return [json.loads(r["data"]) for r in rows]

    def _put_rows(self, table: str, time_key: str, device_id: str, rows: list) -> None:
        with self._lock, closing(self._conn()) as db, db:
            for row in rows or []:
                if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                    continue
                try:
                    at = float(row.get(time_key))
                except (TypeError, ValueError):
                    continue
                db.execute(f"INSERT OR REPLACE INTO {table} (device, id, {'start' if table == 'sessions' else 't'}, data)"
                           f" VALUES (?,?,?,?)", (device_id, row["id"], at, json.dumps(row)))

    # ── energy ───────────────────────────────────────────────────────────
    def energy(self, device_id: str, period: str, price: float, now: Optional[float] = None) -> list:
        """kWh and cost per local day (last 14), week (last 12) or month (last 12), from power.total."""
        now = self.clock() if now is None else now
        count = {"day": 14, "week": 12, "month": 12}.get(period, 14)
        starts = _period_starts(period, now, count)
        t0 = starts[0]
        with closing(self._conn()) as db:
            # 1-minute buckets cover 90 days; the hourly table beyond that.
            table, step = ("m1", 60) if t0 >= now - 90 * 86400 else ("h1", 3600)
            rows = db.execute(f"SELECT t, n, sum FROM {table} WHERE device=? AND key='power.total' AND t>=?",
                              (device_id, t0)).fetchall()
        buckets = [{"start": s, "kwh": 0.0, "cost": 0.0} for s in starts]
        for r in rows:
            watts = r["sum"] / r["n"]
            for b, s in zip(reversed(buckets), reversed(starts)):
                if r["t"] >= s:
                    b["kwh"] += watts * step / 3_600_000   # a bucket with readings counts as on for its span
                    break
        for b in buckets:
            b["kwh"] = round(b["kwh"], 4)
            b["cost"] = round(b["kwh"] * float(price or 0), 4)
        return buckets

    # ── dashboards ───────────────────────────────────────────────────────
    def dashboards(self) -> list:
        with self._lock, closing(self._conn()) as db, db:
            seeded = db.execute("SELECT v FROM meta WHERE k='seeded'").fetchone()
            if seeded is None:
                for i, d in enumerate(default_dashboards()):
                    db.execute("INSERT OR IGNORE INTO dashboards (id, rev, pos, data) VALUES (?,?,?,?)",
                               (d["id"], 1, i, json.dumps(d)))
                db.execute("INSERT INTO meta (k, v) VALUES ('seeded', '1')")
            rows = db.execute("SELECT rev, data FROM dashboards ORDER BY pos, id").fetchall()
        return [{**json.loads(r["data"]), "rev": r["rev"]} for r in rows]

    def dashboard(self, dashboard_id: str) -> Optional[dict]:
        return next((d for d in self.dashboards() if d["id"] == dashboard_id), None)

    def put_dashboard(self, d: dict, rev: Optional[int]) -> dict:
        body = {k: v for k, v in (d or {}).items() if k != "rev"}
        errors = validate_dashboard(body)
        if errors:
            raise ValueError(errors)
        self.dashboards()   # seed first
        with self._lock, closing(self._conn()) as db, db:
            row = db.execute("SELECT rev, pos, data FROM dashboards WHERE id=?", (body["id"],)).fetchone()
            # Writing over an existing dashboard needs its current revision (none = a new one).
            if row is not None and (rev is None or int(rev) != row["rev"]):
                raise Conflict({**json.loads(row["data"]), "rev": row["rev"]})
            if body.get("auto") == "game":   # only one dashboard is the gaming one
                for other in db.execute("SELECT id, rev, data FROM dashboards WHERE id != ?", (body["id"],)).fetchall():
                    od = json.loads(other["data"])
                    if od.get("auto") == "game":
                        od["auto"] = None
                        db.execute("UPDATE dashboards SET data=?, rev=? WHERE id=?", (json.dumps(od), other["rev"] + 1, other["id"]))
            new_rev = (row["rev"] if row else 0) + 1
            pos = row["pos"] if row else (db.execute("SELECT COALESCE(MAX(pos), -1) + 1 FROM dashboards").fetchone()[0])
            db.execute("INSERT OR REPLACE INTO dashboards (id, rev, pos, data) VALUES (?,?,?,?)",
                       (body["id"], new_rev, pos, json.dumps(body)))
        return {**body, "rev": new_rev}

    def delete_dashboard(self, dashboard_id: str) -> bool:
        self.dashboards()
        with self._lock, closing(self._conn()) as db, db:
            return db.execute("DELETE FROM dashboards WHERE id=?", (dashboard_id,)).rowcount > 0


def _merge(rows: list) -> list:
    n = sum(r["n"] for r in rows)
    return [float(rows[0]["t"]), round(sum(r["sum"] for r in rows) / n, 3),
            round(min(r["min"] for r in rows), 3), round(max(r["max"] for r in rows), 3)]


def _period_starts(period: str, now: float, count: int) -> list[float]:
    import datetime as dt
    today = dt.datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
    out: list[dt.datetime] = []
    if period == "week":
        start = today - dt.timedelta(days=today.weekday())
        out = [start - dt.timedelta(weeks=i) for i in range(count)]
    elif period == "month":
        y, m = today.year, today.month
        for _ in range(count):
            out.append(dt.datetime(y, m, 1))
            y, m = (y - 1, 12) if m == 1 else (y, m - 1)
    else:
        out = [today - dt.timedelta(days=i) for i in range(count)]
    return sorted(o.timestamp() for o in out)


_STORE: Optional[PcStatsStore] = None
_STORE_LOCK = threading.Lock()


def store() -> PcStatsStore:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            from jarviscopilot_constants import get_hermes_home
            _STORE = PcStatsStore(get_hermes_home() / "pc_stats")
        return _STORE
