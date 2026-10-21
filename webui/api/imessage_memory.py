"""iMessage memory: what the Mac uploads, waiting to become long-term memory.

The Mac client reads his Messages database and uploads the messages of the
chats he lets Jarvis remember. They wait here, per chat, until a conversation
burst has gone quiet for ``GAP_SECONDS``; then ``imessage_memory_writer`` turns
the burst into a transcript memory plus extracted facts and records it in
``bursts``, which is also what keeps a re-uploaded or backfilled message from
being remembered twice.

Own SQLite file under $HERMES_HOME, connection per call (the webui is a
thread-per-request server; live_store does the same).
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

GAP_SECONDS = 1800  # a burst ends after 30 min of quiet
ACTIVE_JOB_STATES = ("pending", "running")            # the Mac is (or will be) uploading
LIVE_JOB_STATES = ("pending", "running", "analyzing")  # ...or Jarvis is still reading it
# A job's rows: received minus those still waiting is how far the analysis got.
_JOB_SELECT = ("SELECT j.*, (SELECT COUNT(*) FROM pending p WHERE p.job_id = j.id) AS waiting "
               "FROM jobs j")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS chats (
    guid            TEXT PRIMARY KEY,
    name            TEXT NOT NULL DEFAULT '',
    is_group        INTEGER NOT NULL DEFAULT 0,
    participants    TEXT NOT NULL DEFAULT '[]',
    last_message_at REAL,
    pick            INTEGER,
    remembered      INTEGER NOT NULL DEFAULT 0,
    updated_at      REAL
);
CREATE TABLE IF NOT EXISTS pending (
    guid       TEXT NOT NULL,
    rowid      INTEGER NOT NULL,
    ts         REAL NOT NULL,
    sender     TEXT NOT NULL DEFAULT '',
    handle     TEXT NOT NULL DEFAULT '',
    is_from_me INTEGER NOT NULL DEFAULT 0,
    text       TEXT NOT NULL,
    job_id     TEXT,
    PRIMARY KEY (guid, rowid)
);
CREATE TABLE IF NOT EXISTS bursts (
    guid        TEXT NOT NULL,
    first_rowid INTEGER NOT NULL,
    last_rowid  INTEGER NOT NULL,
    start       REAL NOT NULL,
    end         REAL NOT NULL,
    count       INTEGER NOT NULL,
    status      TEXT NOT NULL,
    created_at  REAL NOT NULL,
    PRIMARY KEY (guid, first_rowid)
);
CREATE TABLE IF NOT EXISTS fact_cards (
    id          TEXT PRIMARY KEY,
    guid        TEXT NOT NULL,
    first_rowid INTEGER NOT NULL,
    last_rowid  INTEGER NOT NULL,
    chat_name   TEXT NOT NULL DEFAULT '',
    fact        TEXT NOT NULL,
    body        TEXT NOT NULL,
    source      TEXT NOT NULL,
    at          REAL NOT NULL,
    created_at  REAL NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    decided_at  REAL
);
CREATE INDEX IF NOT EXISTS ix_fact_cards_status ON fact_cards(status, created_at);
CREATE INDEX IF NOT EXISTS ix_pending_job ON pending(job_id);
CREATE TABLE IF NOT EXISTS jobs (
    id         TEXT PRIMARY KEY,
    start      REAL NOT NULL,
    end        REAL NOT NULL,
    chats      TEXT,
    status     TEXT NOT NULL,
    received   INTEGER NOT NULL DEFAULT 0,
    stored     INTEGER NOT NULL DEFAULT 0,
    skipped    INTEGER NOT NULL DEFAULT 0,
    error      TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
"""

_DEFAULT_SETTINGS = {"enabled": False, "enabled_at": None, "agent": None, "skip": [],
                     "mac_device_id": "", "mac_seen_at": None,
                     # Facts from new conversations wait as Store/Skip cards; pushes
                     # announce them on the lock screen. Both his switches.
                     "ask_facts": True, "push_facts": True}
FACT_CARD_TTL = 86400  # an unanswered card is stored after a day
# A backfill the Mac stopped answering: running but silent this long, or never
# started this long after he asked, fails so it can't block the next one.
STALE_RUNNING_SECONDS = 1800
STALE_PENDING_SECONDS = 86400


def normalize_handle(handle) -> str:
    """The same key the Mac uses: an email lowercased, a phone number's last 10
    digits ("+1 (510) 555-0000" == "5105550000")."""
    h = str(handle or "").strip().lower()
    if "@" in h:
        return h
    digits = "".join(ch for ch in h if ch.isdigit())
    return digits[-10:] if digits else h


@dataclass
class Burst:
    guid: str
    rows: list = field(default_factory=list)  # dicts: rowid, ts, sender, handle, is_from_me, text, job_id

    @property
    def first_rowid(self) -> int:
        return min(r["rowid"] for r in self.rows)

    @property
    def last_rowid(self) -> int:
        return max(r["rowid"] for r in self.rows)

    @property
    def start(self) -> float:
        return self.rows[0]["ts"]

    @property
    def end(self) -> float:
        return self.rows[-1]["ts"]

    @property
    def job_ids(self) -> set:
        return {r["job_id"] for r in self.rows if r.get("job_id")}


class IMStore:
    def __init__(self, path) -> None:
        self.path = Path(path)
        self._schema_lock = threading.Lock()
        self._ready = False

    @contextmanager
    def _db(self):
        if not self._ready:
            with self._schema_lock:
                if not self._ready:
                    self.path.parent.mkdir(parents=True, exist_ok=True)
                    conn = sqlite3.connect(self.path, timeout=10)
                    conn.execute("PRAGMA journal_mode=WAL")
                    conn.executescript(_SCHEMA)
                    conn.close()
                    self._ready = True
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=10000")
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    # ── settings ─────────────────────────────────────────────────────────
    def settings(self) -> dict:
        out = dict(_DEFAULT_SETTINGS)
        with self._db() as db:
            for row in db.execute("SELECT k, v FROM settings"):
                try:
                    out[row["k"]] = json.loads(row["v"])
                except (TypeError, ValueError):
                    pass
        return out

    def update_settings(self, **fields) -> dict:
        if fields.get("enabled") and not self.settings().get("enabled"):
            # When he switched it on: the Mac sends nothing older (an iCloud
            # history download arrives with new ROWIDs but old dates).
            fields.setdefault("enabled_at", time.time())
        with self._db() as db:
            for key, value in fields.items():
                if key in _DEFAULT_SETTINGS:
                    db.execute("INSERT OR REPLACE INTO settings(k, v) VALUES (?, ?)",
                               (key, json.dumps(value)))
        return self.settings()

    def skip_keys(self, settings: Optional[dict] = None) -> set:
        skip = (settings or self.settings()).get("skip") or []
        return {normalize_handle(s.get("handle") if isinstance(s, dict) else s) for s in skip} - {""}

    # ── chats ────────────────────────────────────────────────────────────
    def upsert_chats(self, chats: Iterable[dict]) -> None:
        now = time.time()
        with self._db() as db:
            for chat in chats:
                guid = str(chat.get("guid") or "").strip()
                if not guid:
                    continue
                db.execute(
                    "INSERT INTO chats(guid, name, is_group, participants, last_message_at, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(guid) DO UPDATE SET "
                    "name=excluded.name, is_group=excluded.is_group, "
                    "participants=excluded.participants, "
                    "last_message_at=MAX(IFNULL(chats.last_message_at, 0), "
                    "IFNULL(excluded.last_message_at, 0)), updated_at=excluded.updated_at",
                    (guid, str(chat.get("name") or "")[:200], 1 if chat.get("is_group") else 0,
                     json.dumps(_participants(chat.get("participants"))),
                     _float(chat.get("last_message_at")), now))

    def chats(self) -> list:
        with self._db() as db:
            rows = db.execute("SELECT * FROM chats ORDER BY IFNULL(last_message_at, 0) DESC").fetchall()
        return [_chat_dict(r) for r in rows]

    def chat(self, guid: str) -> Optional[dict]:
        with self._db() as db:
            row = db.execute("SELECT * FROM chats WHERE guid=?", (guid,)).fetchone()
        return _chat_dict(row) if row else None

    def set_pick(self, guid: str, pick: Optional[bool]) -> None:
        with self._db() as db:
            db.execute("INSERT INTO chats(guid, pick, updated_at) VALUES (?, ?, ?) "
                       "ON CONFLICT(guid) DO UPDATE SET pick=excluded.pick",
                       (guid, None if pick is None else int(bool(pick)), time.time()))

    def effective_pick(self, chat: dict, skip: Optional[set] = None) -> bool:
        """Whether this chat is remembered, ignoring the on/off switch: the skip
        list wins, then his explicit pick, then 1:1 on / group off."""
        skip = self.skip_keys() if skip is None else skip
        if any(normalize_handle(p.get("handle")) in skip for p in chat.get("participants") or []):
            return False
        if chat.get("pick") is not None:
            return bool(chat["pick"])
        return not chat.get("is_group")

    def chat_allowed(self, guid: str, settings: Optional[dict] = None) -> bool:
        settings = settings or self.settings()
        if not settings.get("enabled"):
            return False
        chat = self.chat(guid)
        return bool(chat) and self.effective_pick(chat, self.skip_keys(settings))

    # ── messages ─────────────────────────────────────────────────────────
    def ingest(self, messages: Iterable[dict], job_id: Optional[str] = None) -> dict:
        """Buffer uploaded messages. Rejects chats he doesn't allow (a stale Mac
        config) and skip-listed senders; drops ones already inside a stored
        burst or already buffered. Chat details riding on a message create the
        chat row when the Mac's list hasn't arrived yet."""
        messages = list(messages or [])
        self.upsert_chats({"guid": m.get("guid"), "name": m.get("chat_name") or "",
                           "is_group": m.get("is_group"), "participants": m.get("participants"),
                           "last_message_at": m.get("ts")}
                          for m in messages if m.get("participants") is not None)
        settings = self.settings()
        skip = self.skip_keys(settings)
        allowed: dict = {}
        counts = {"accepted": 0, "duplicate": 0, "rejected": 0}
        with self._db() as db:
            for m in messages:
                guid = str(m.get("guid") or "")
                text = str(m.get("text") or "").strip()
                try:
                    rowid = int(m.get("rowid"))
                    ts = float(m.get("ts"))
                except (TypeError, ValueError):
                    counts["rejected"] += 1
                    continue
                if guid not in allowed:
                    row = db.execute("SELECT * FROM chats WHERE guid=?", (guid,)).fetchone()
                    allowed[guid] = bool(settings.get("enabled")) and bool(row) and \
                        self.effective_pick(_chat_dict(row), skip)
                if not text or not allowed[guid] or normalize_handle(m.get("handle")) in skip:
                    counts["rejected"] += 1
                    continue
                if db.execute("SELECT 1 FROM bursts WHERE guid=? AND ? BETWEEN first_rowid AND last_rowid "
                              "AND ? BETWEEN start AND end", (guid, rowid, ts)).fetchone():
                    counts["duplicate"] += 1
                    continue
                cur = db.execute(
                    "INSERT OR IGNORE INTO pending(guid, rowid, ts, sender, handle, is_from_me, text, job_id) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (guid, rowid, ts, str(m.get("sender") or "")[:120], str(m.get("handle") or ""),
                     1 if m.get("is_from_me") else 0, text[:4000], job_id))
                counts["accepted" if cur.rowcount else "duplicate"] += 1
            if job_id:
                db.execute("UPDATE jobs SET received=received+?, skipped=skipped+?, updated_at=?, "
                           "status=CASE WHEN status='pending' THEN 'running' ELSE status END WHERE id=?",
                           (counts["accepted"], counts["duplicate"], time.time(), job_id))
        return counts

    def open_bursts(self, now: float) -> list:
        """Bursts ready to remember: a chat's buffered messages split at quiet
        gaps; one closes when it has been quiet for GAP_SECONDS, or — backfill —
        when its job is over. A backfill burst never closes while its job is
        still uploading, or a conversation split across two batches would
        become two memories."""
        with self._db() as db:
            active = {r["id"] for r in db.execute(
                f"SELECT id FROM jobs WHERE status IN {ACTIVE_JOB_STATES}")}
            rows = [dict(r) for r in db.execute("SELECT * FROM pending ORDER BY guid, ts, rowid")]
        out: list = []
        by_chat: dict = {}
        for r in rows:
            by_chat.setdefault(r["guid"], []).append(r)
        for guid, chat_rows in by_chat.items():
            current = Burst(guid)
            segments = [current]
            for r in chat_rows:
                if current.rows and r["ts"] - current.end >= GAP_SECONDS:
                    current = Burst(guid)
                    segments.append(current)
                current.rows.append(r)
            for burst in segments:
                if burst.job_ids & active:
                    continue
                all_backfill = all(r.get("job_id") for r in burst.rows)
                if all_backfill or now - burst.end >= GAP_SECONDS:
                    out.append(burst)
        return out

    def still_pending(self, burst: Burst) -> bool:
        """Whether every row of the burst is still buffered (Forget clears them)."""
        with self._db() as db:
            n = db.execute(f"SELECT COUNT(*) FROM pending WHERE guid=? AND rowid IN "
                           f"({','.join('?' * len(burst.rows))})",
                           (burst.guid, *[r["rowid"] for r in burst.rows])).fetchone()[0]
        return n == len(burst.rows)

    def begin_burst(self, burst: Burst) -> None:
        """Note a burst whose memories are being written, so a crash midway is
        undone and redone at the next start (``storing_bursts``)."""
        with self._db() as db:
            # Cards an earlier, cut-off attempt at this burst left behind.
            db.execute("DELETE FROM fact_cards WHERE guid=? AND first_rowid=? AND status='pending'",
                       (burst.guid, burst.first_rowid))
            db.execute("INSERT OR REPLACE INTO bursts(guid, first_rowid, last_rowid, start, end, count, "
                       "status, created_at) VALUES (?, ?, ?, ?, ?, ?, 'storing', ?)",
                       (burst.guid, burst.first_rowid, burst.last_rowid, burst.start, burst.end,
                        len(burst.rows), time.time()))

    def storing_bursts(self) -> list:
        with self._db() as db:
            return [dict(r) for r in db.execute("SELECT * FROM bursts WHERE status='storing'")]

    def drop_burst_record(self, guid: str, first_rowid: int) -> None:
        with self._db() as db:
            db.execute("DELETE FROM bursts WHERE guid=? AND first_rowid=?", (guid, first_rowid))

    def mark_burst(self, burst: Burst, status: str, remembered: bool = True) -> bool:
        """Record a remembered burst (the dedupe record), drop its buffered rows.
        False, recording nothing, when its rows are gone — he pressed Forget
        while it was being written, and the caller must take its memories back."""
        with self._db() as db:
            gone = db.executemany("DELETE FROM pending WHERE guid=? AND rowid=?",
                                  [(burst.guid, r["rowid"]) for r in burst.rows]).rowcount
            if gone <= 0:
                db.execute("DELETE FROM bursts WHERE guid=? AND first_rowid=?",
                           (burst.guid, burst.first_rowid))
                return False
            db.execute("INSERT OR REPLACE INTO bursts(guid, first_rowid, last_rowid, start, end, count, "
                       "status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       (burst.guid, burst.first_rowid, burst.last_rowid, burst.start, burst.end,
                        len(burst.rows), status, time.time()))
            if remembered:
                db.execute("UPDATE chats SET remembered=remembered+1 WHERE guid=?", (burst.guid,))
            for job_id in burst.job_ids:
                db.execute("UPDATE jobs SET stored=stored+1, updated_at=? WHERE id=?",
                           (time.time(), job_id))
        return True

    def drop_burst(self, burst: Burst) -> None:
        """Throw a burst away unremembered (its chat was unticked meanwhile)."""
        with self._db() as db:
            self._delete_rows(db, burst)

    @staticmethod
    def _delete_rows(db, burst: Burst) -> None:
        db.executemany("DELETE FROM pending WHERE guid=? AND rowid=?",
                       [(burst.guid, r["rowid"]) for r in burst.rows])

    def forget_chat(self, guid: str) -> None:
        with self._db() as db:
            db.execute("DELETE FROM fact_cards WHERE guid=?", (guid,))
            db.execute("DELETE FROM bursts WHERE guid=?", (guid,))
            db.execute("DELETE FROM pending WHERE guid=?", (guid,))
            db.execute("UPDATE chats SET remembered=0 WHERE guid=?", (guid,))

    # ── fact cards ───────────────────────────────────────────────────────
    def add_fact_cards(self, burst: Burst, chat_name: str, facts: list, source: str) -> list:
        """One pending Store/Skip card per ``(fact, body)``; ``body`` is what
        gets remembered (the fact with its who/when stamp)."""
        now = time.time()
        rows = [(uuid.uuid4().hex[:16], burst.guid, burst.first_rowid, burst.last_rowid,
                 chat_name[:120], fact, body, source, burst.start, now) for fact, body in facts]
        with self._db() as db:
            db.executemany("INSERT INTO fact_cards(id, guid, first_rowid, last_rowid, chat_name, fact, body, "
                           "source, at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
        return [_card_dict(r) for r in rows]

    def pending_facts(self, limit: int = 50) -> list:
        with self._db() as db:
            rows = db.execute("SELECT * FROM fact_cards WHERE status='pending' "
                              "ORDER BY created_at DESC, rowid LIMIT ?", (limit,)).fetchall()
        return [_card_out(r) for r in rows]

    def pending_count(self) -> int:
        with self._db() as db:
            return db.execute("SELECT COUNT(*) FROM fact_cards WHERE status='pending'").fetchone()[0]

    def take_cards(self, ids=None, burst: Optional[str] = None) -> list:
        """Claim pending cards for a decision: flips them to ``deciding`` in one
        transaction, so the app and a lock-screen action pressed together can't
        both store the same fact. ``burst`` is ``"<guid>|<first_rowid>"``."""
        where, args = [], []
        if ids:
            where.append(f"id IN ({','.join('?' * len(ids))})")
            args += list(ids)
        if burst:
            guid, _, first = str(burst).rpartition("|")
            try:
                args += [guid, int(first)]
            except ValueError:
                return []
            where.append("(guid=? AND first_rowid=?)")
        if not where:
            return []
        cond = " OR ".join(where)
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            rows = db.execute(f"SELECT * FROM fact_cards WHERE status='pending' AND ({cond})", args).fetchall()
            db.executemany("UPDATE fact_cards SET status='deciding' WHERE id=? AND status='pending'",
                           [(r["id"],) for r in rows])
        return [dict(r) for r in rows]

    def expired_cards(self, now: float) -> list:
        """Pending cards past FACT_CARD_TTL, claimed (``deciding``) for auto-store."""
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            rows = db.execute("SELECT * FROM fact_cards WHERE status='pending' AND created_at < ?",
                              (now - FACT_CARD_TTL,)).fetchall()
            db.executemany("UPDATE fact_cards SET status='deciding' WHERE id=?", [(r["id"],) for r in rows])
        return [dict(r) for r in rows]

    def finish_cards(self, ids: list, status: str) -> set:
        """Close claimed cards; returns the ids actually closed. A missing one
        was deleted meanwhile (Forget), and its memory must be taken back."""
        done = set()
        with self._db() as db:
            for i in ids:
                if db.execute("UPDATE fact_cards SET status=?, decided_at=? WHERE id=? AND status='deciding'",
                              (status, time.time(), i)).rowcount:
                    done.add(i)
        return done

    def release_stuck_cards(self) -> int:
        """Cards a restart left mid-decision go back to waiting."""
        with self._db() as db:
            return db.execute("UPDATE fact_cards SET status='pending' WHERE status='deciding'").rowcount

    def release_cards(self, ids: list) -> None:
        """Put claimed cards back (a memory write failed)."""
        with self._db() as db:
            db.executemany("UPDATE fact_cards SET status='pending' WHERE id=? AND status='deciding'",
                           [(i,) for i in ids])

    def delete_cards(self, guid: str, first_rowid: Optional[int] = None) -> None:
        with self._db() as db:
            if first_rowid is None:
                db.execute("DELETE FROM fact_cards WHERE guid=?", (guid,))
            else:
                db.execute("DELETE FROM fact_cards WHERE guid=? AND first_rowid=?", (guid, first_rowid))

    def totals(self) -> dict:
        with self._db() as db:
            bursts = db.execute("SELECT COUNT(*) FROM bursts").fetchone()[0]
            pending = db.execute("SELECT COUNT(*) FROM pending").fetchone()[0]
        return {"bursts": bursts, "pending": pending}

    # ── backfill jobs ────────────────────────────────────────────────────
    def create_job(self, start: float, end: float, chats: Optional[list] = None) -> dict:
        if self.active_job():
            raise ValueError("busy")
        now = time.time()
        job_id = uuid.uuid4().hex[:12]
        with self._db() as db:
            db.execute("INSERT INTO jobs(id, start, end, chats, status, created_at, updated_at) "
                       "VALUES (?, ?, ?, ?, 'pending', ?, ?)",
                       (job_id, float(start), float(end),
                        json.dumps(list(chats)) if chats else None, now, now))
        return self.job(job_id)

    def job(self, job_id: str) -> Optional[dict]:
        with self._db() as db:
            row = db.execute(f"{_JOB_SELECT} WHERE j.id=?", (job_id,)).fetchone()
        return _job_dict(row) if row else None

    def jobs(self, limit: int = 10) -> list:
        with self._db() as db:
            rows = db.execute(f"{_JOB_SELECT} ORDER BY j.created_at DESC LIMIT ?", (limit,)).fetchall()
        return [_job_dict(r) for r in rows]

    def active_job(self, states=LIVE_JOB_STATES) -> Optional[dict]:
        """The backfill still in progress — uploading or being analysed."""
        states = tuple(states)
        with self._db() as db:
            row = db.execute(f"{_JOB_SELECT} WHERE j.status IN ({','.join('?' * len(states))}) "
                             "ORDER BY j.created_at DESC LIMIT 1", states).fetchone()
        return _job_dict(row) if row else None

    def finish_analyzed_jobs(self) -> int:
        """An analysing backfill with nothing left waiting is done."""
        with self._db() as db:
            return db.execute("UPDATE jobs SET status='done', updated_at=? WHERE status='analyzing' AND "
                              "NOT EXISTS (SELECT 1 FROM pending p WHERE p.job_id = jobs.id)",
                              (time.time(),)).rowcount

    def stop_job(self, job_id: str) -> None:
        """Stop a backfill wherever it is; what it uploaded but wasn't read yet is dropped."""
        with self._db() as db:
            db.execute(f"UPDATE jobs SET status='stopped', updated_at=? WHERE id=? AND status IN {LIVE_JOB_STATES}",
                       (time.time(), job_id))
            db.execute("DELETE FROM pending WHERE job_id=?", (job_id,))

    def expire_jobs(self, now: float) -> int:
        """Fail a backfill the Mac stopped answering (see STALE_*), so its rows
        close and the next backfill isn't refused."""
        with self._db() as db:
            return db.execute(
                "UPDATE jobs SET status='error', error=?, updated_at=? WHERE "
                "(status='running' AND updated_at < ?) OR (status='pending' AND updated_at < ?)",
                ("Your Mac stopped responding", now, now - STALE_RUNNING_SECONDS,
                 now - STALE_PENDING_SECONDS)).rowcount

    def stop_active_jobs(self) -> None:
        for state in LIVE_JOB_STATES:
            job = self.active_job(states=(state,))
            while job:
                self.stop_job(job["id"])
                job = self.active_job(states=(state,))

    def update_job(self, job_id: str, **fields) -> Optional[dict]:
        allowed = {k: v for k, v in fields.items() if k in ("status", "error")}
        if allowed:
            sets = ", ".join(f"{k}=?" for k in allowed)
            with self._db() as db:
                db.execute(f"UPDATE jobs SET {sets}, updated_at=? WHERE id=?",
                           (*allowed.values(), time.time(), job_id))
        return self.job(job_id)


def _float(value) -> Optional[float]:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _participants(value) -> list:
    out = []
    for p in value or []:
        if isinstance(p, dict) and (p.get("handle") or p.get("label")):
            out.append({"handle": str(p.get("handle") or ""), "label": str(p.get("label") or "")})
    return out


def _chat_dict(row) -> dict:
    d = dict(row)
    try:
        d["participants"] = json.loads(d.get("participants") or "[]")
    except ValueError:
        d["participants"] = []
    d["is_group"] = bool(d.get("is_group"))
    d["pick"] = None if d.get("pick") is None else bool(d["pick"])
    return d


def _card_dict(row: tuple) -> dict:
    keys = ("id", "guid", "first_rowid", "last_rowid", "chat_name", "fact", "body", "source", "at", "created_at")
    return dict(zip(keys, row))


def _card_out(row) -> dict:
    """What the phone shows: no stamped body, plus when it auto-stores."""
    return {"id": row["id"], "guid": row["guid"], "chat_name": row["chat_name"], "fact": row["fact"],
            "at": row["at"], "expires_at": row["created_at"] + FACT_CARD_TTL,
            "burst": f"{row['guid']}|{row['first_rowid']}"}


def _job_dict(row) -> dict:
    d = dict(row)
    waiting = int(d.pop("waiting", 0) or 0)
    d["analyzed"] = max(0, int(d.get("received") or 0) - waiting)
    try:
        d["chats"] = json.loads(d["chats"]) if d.get("chats") else None
    except ValueError:
        d["chats"] = None
    return d


_store: Optional[IMStore] = None
_store_lock = threading.Lock()


def store() -> IMStore:
    """The process's store, under the active profile's $HERMES_HOME."""
    global _store
    with _store_lock:
        if _store is None:
            from jarviscopilot_constants import get_hermes_home
            _store = IMStore(Path(get_hermes_home()) / "imessage_memory.db")
        return _store
