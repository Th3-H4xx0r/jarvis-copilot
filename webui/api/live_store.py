"""Storage for Live Jarvis — ambient conversation transcripts.

`live.db` is deliberately its own SQLite file rather than tables in `state.db`.
An always-on transcript writes constantly and SQLite allows one writer, so
sharing the agent's session store would make the agent wait on the recorder.

Everything here is synchronous and connection-per-call. SQLite connections are
cheap to open, WAL lets readers run alongside the single writer, and the webui
is a thread-per-request server — so a per-call connection is both the simplest
and the safest choice. There is no module-level connection to leak across
threads.

Audio is NOT stored here. Chunks live on disk at
``STATE_DIR/live/<live_session_id>/<chunk>.opus`` and `live_audio` rows point at
them, so deleting a day is a file unlink plus a row delete.
"""
from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
import struct
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable, Optional

# Guards schema creation only. Writes rely on SQLite's own locking (WAL +
# busy_timeout), not on this lock, so a second process still behaves.
_SCHEMA_LOCK = threading.Lock()
_schema_ready = False

logger = logging.getLogger(__name__)

LABEL_PROVISIONAL = "provisional"
LABEL_CONFIRMED = "confirmed"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS live_session (
    id               TEXT PRIMARY KEY,
    started_at       REAL NOT NULL,
    ended_at         REAL,
    title            TEXT,
    device_id        TEXT,
    source_label     TEXT,
    chat_session_id  TEXT,
    last_seq         INTEGER NOT NULL DEFAULT 0,
    state            TEXT NOT NULL DEFAULT 'recording'
);

CREATE TABLE IF NOT EXISTS live_segment (
    live_session_id  TEXT NOT NULL,
    seq              INTEGER NOT NULL,
    ts_start_ms      INTEGER NOT NULL,
    ts_end_ms        INTEGER NOT NULL,
    speaker_id       TEXT,
    speaker_conf     REAL,
    label_state      TEXT NOT NULL DEFAULT 'provisional',
    local_label      TEXT,
    text             TEXT NOT NULL,
    lang             TEXT,
    translation      TEXT,
    device_id        TEXT,
    audio_ref        TEXT,
    PRIMARY KEY (live_session_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_segment_speaker ON live_segment(speaker_id);
CREATE INDEX IF NOT EXISTS idx_segment_time ON live_segment(ts_start_ms);

CREATE VIRTUAL TABLE IF NOT EXISTS live_segment_fts USING fts5(
    text, live_session_id UNINDEXED, seq UNINDEXED, tokenize='porter'
);

CREATE TABLE IF NOT EXISTS speaker (
    id             TEXT PRIMARY KEY,
    kind           TEXT NOT NULL DEFAULT 'other',
    name           TEXT,
    created_at     REAL NOT NULL,
    last_heard_at  REAL,
    segment_count  INTEGER NOT NULL DEFAULT 0,
    speech_ms      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS speaker_embedding (
    id            TEXT PRIMARY KEY,
    speaker_id    TEXT NOT NULL,
    vec           BLOB NOT NULL,
    model         TEXT NOT NULL,
    from_segment  TEXT,
    created_at    REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_embedding_speaker ON speaker_embedding(speaker_id);

CREATE TABLE IF NOT EXISTS live_digest (
    id               TEXT PRIMARY KEY,
    live_session_id  TEXT NOT NULL,
    seq_from         INTEGER NOT NULL,
    seq_to           INTEGER NOT NULL,
    ts_start_ms      INTEGER,
    ts_end_ms        INTEGER,
    summary          TEXT NOT NULL,
    topics           TEXT,
    speaker_ids      TEXT,
    actions          TEXT,
    model            TEXT,
    created_at       REAL NOT NULL,
    embedding        BLOB,
    scope            TEXT NOT NULL DEFAULT 'window'
);
CREATE INDEX IF NOT EXISTS idx_digest_session ON live_digest(live_session_id);

CREATE VIRTUAL TABLE IF NOT EXISTS live_digest_fts USING fts5(
    summary, topics, id UNINDEXED, live_session_id UNINDEXED, tokenize='porter'
);

-- A watcher's output, kept rather than only fanned out. An insight used to
-- exist solely as a frame, so one produced while the phone was backgrounded or
-- reconnecting (design §8: the stream drops about once a minute) reached nobody
-- and could never be asked for again — the paired chat kept it, the Live screen
-- could not. `seq_from`/`seq_to` carry the RANGE it covers, because a
-- conversation-level verdict is not about one utterance and pinning it to
-- whichever row happened to be last is the behaviour that was complained about.
CREATE TABLE IF NOT EXISTS live_insight (
    id               TEXT PRIMARY KEY,
    live_session_id  TEXT NOT NULL,
    kind             TEXT NOT NULL,
    text             TEXT NOT NULL,
    seq_from         INTEGER,
    seq_to           INTEGER,
    -- WHERE the card goes, which is not the same question as what the note
    -- covered. A conversation-level fact-check reads a stretch (the range) and
    -- judges one claim inside it (the anchor). Collapsing the range onto the
    -- anchor placed the card correctly and then hid it from every client
    -- resuming past that row, because `insights_for_session` filters on
    -- `seq_to`.
    anchor_seq       INTEGER,
    scope            TEXT,
    verdict          TEXT,
    sources          TEXT,
    digest_id        TEXT,
    created_at       REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_insight_session
    ON live_insight(live_session_id, seq_to);

CREATE TABLE IF NOT EXISTS live_audio (
    id               TEXT PRIMARY KEY,
    live_session_id  TEXT NOT NULL,
    path             TEXT NOT NULL,
    codec            TEXT,
    ts0_ms           INTEGER,
    ts1_ms           INTEGER,
    bytes            INTEGER NOT NULL DEFAULT 0,
    device_id        TEXT
);
CREATE INDEX IF NOT EXISTS idx_audio_session ON live_audio(live_session_id);
-- One row per file. Two paths can register the same chunk: the startup sweep
-- racing a roll, or a client whose timestamps make the writer reuse a stem.
-- Both double-counted the bytes and let one delete unlink a file another row
-- still pointed at.
CREATE UNIQUE INDEX IF NOT EXISTS idx_audio_path ON live_audio(path);
"""


def _ensure_schema(conn: sqlite3.Connection) -> None:
    global _schema_ready
    if _schema_ready:
        return
    with _SCHEMA_LOCK:
        if _schema_ready:
            return
        conn.executescript(_SCHEMA)
        _add_missing_columns(conn)
        conn.commit()
        _schema_ready = True


# Columns added after the first release. `CREATE TABLE IF NOT EXISTS` is a
# no-op on a table that already exists, so a new column reaches an existing
# database only through an ALTER. Additive and nullable only: this runs on
# every open, against a database holding recordings that cannot be recreated.
_ADDED_COLUMNS = (
    ("live_insight", "anchor_seq", "INTEGER"),
)


def _add_missing_columns(conn: sqlite3.Connection) -> None:
    for table, column, decl in _ADDED_COLUMNS:
        have = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if not have or column in have:
            continue
        try:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
        except sqlite3.OperationalError:
            # Another process added it between the check and the ALTER.
            logger.debug("live: %s.%s already added", table, column,
                         exc_info=True)


def reset_for_tests() -> None:
    """Forget that the schema was created. Tests point STATE_DIR at a tmp dir
    per test; without this the second test would skip creation on a fresh file."""
    global _schema_ready
    _schema_ready = False


def _db_path() -> Path:
    # Read STATE_DIR at call time, not import time: tests monkeypatch it, and a
    # profile switch changes it too.
    from api import config as _config
    return Path(_config.STATE_DIR) / "live.db"


def _audio_root() -> Path:
    from api import config as _config
    return Path(_config.STATE_DIR) / "live"


@contextmanager
def connect():
    """A connection with WAL and a busy timeout, closed on exit."""
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=10.0)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=10000")
        # Without this, a deleted utterance stays legible in the file's free
        # pages — `strings live.db` prints it back, verified. For a store of
        # other people's conversations, "deleted" has to mean unreadable, not
        # merely unlinked from an index.
        conn.execute("PRAGMA secure_delete=ON")
        _ensure_schema(conn)
        yield conn
    finally:
        conn.close()


def _row_to_dict(row: Optional[sqlite3.Row]) -> Optional[dict]:
    return dict(row) if row is not None else None


# ── sessions ───────────────────────────────────────────────────────────────


def start_session(device_id: str = "", title: str = "",
                  chat_session_id: str = "", source_label: str = "") -> dict:
    """Open a live session. Returns the row.

    `source_label` records WHICH mic this is — "AirPods Pro", "Jarvis glasses",
    "iPhone mic" — because a transcript's quality depends on it and the user
    picks the source per session.
    """
    sid = uuid.uuid4().hex
    now = time.time()
    with connect() as conn:
        conn.execute(
            "INSERT INTO live_session (id, started_at, title, device_id,"
            " source_label, chat_session_id, last_seq, state)"
            " VALUES (?,?,?,?,?,?,0,'recording')",
            (sid, now, title or None, device_id or None, source_label or None,
             chat_session_id or None))
        conn.commit()
    return {"id": sid, "started_at": now, "title": title or None,
            "device_id": device_id or None,
            "source_label": source_label or None,
            "chat_session_id": chat_session_id or None,
            "last_seq": 0, "state": "recording", "ended_at": None}


def get_session(live_session_id: str) -> Optional[dict]:
    with connect() as conn:
        cur = conn.execute("SELECT * FROM live_session WHERE id=?",
                           (live_session_id,))
        return _row_to_dict(cur.fetchone())


def end_session(live_session_id: str) -> None:
    with connect() as conn:
        conn.execute(
            "UPDATE live_session SET state='ended', ended_at=? WHERE id=?",
            (time.time(), live_session_id))
        conn.commit()


def set_chat_session(live_session_id: str, chat_session_id: str) -> None:
    with connect() as conn:
        conn.execute("UPDATE live_session SET chat_session_id=? WHERE id=?",
                     (chat_session_id, live_session_id))
        conn.commit()


def set_source_label(live_session_id: str, source_label: str) -> None:
    """The user switched mics mid-session (unplugged AirPods, say)."""
    with connect() as conn:
        conn.execute("UPDATE live_session SET source_label=? WHERE id=?",
                     (source_label or None, live_session_id))
        conn.commit()


def list_sessions(limit: int = 50) -> list:
    with connect() as conn:
        cur = conn.execute(
            "SELECT * FROM live_session ORDER BY started_at DESC LIMIT ?",
            (int(limit),))
        return [dict(r) for r in cur.fetchall()]


# ── segments ───────────────────────────────────────────────────────────────


def append_segment(live_session_id: str, *, ts_start_ms: int, ts_end_ms: int,
                   text: str, lang: str = "", speaker_id: str = "",
                   speaker_conf: Optional[float] = None,
                   label_state: str = LABEL_PROVISIONAL,
                   local_label: str = "", device_id: str = "",
                   audio_ref: str = "") -> dict:
    """Append one finalized utterance and return it, `seq` included.

    `seq` is allocated inside the same transaction that inserts the row, so two
    devices streaming into one session cannot collide on it.
    """
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        cur = conn.execute("SELECT last_seq FROM live_session WHERE id=?",
                           (live_session_id,))
        row = cur.fetchone()
        if row is None:
            conn.rollback()
            raise KeyError(f"no live session {live_session_id}")
        # A `seg` frame carries no client-side id and the server assigns `seq`,
        # so a client re-sending its spool after a dropped socket (the normal
        # case — a real phone drops about once a minute) would store the same
        # utterance twice under two seqs, which seq-based dedupe cannot catch.
        # The only identity available is the content and its span. Segments
        # ingested without timestamps are NOT deduped: two people saying "yes"
        # with no span are genuinely two utterances, and merging them would lose
        # real speech to protect against a duplicate.
        if int(ts_end_ms) > int(ts_start_ms):
            dup = conn.execute(
                "SELECT * FROM live_segment WHERE live_session_id=?"
                " AND ts_start_ms=? AND ts_end_ms=? AND text=?",
                (live_session_id, int(ts_start_ms), int(ts_end_ms), text)
            ).fetchone()
            if dup is not None:
                conn.rollback()
                return dict(dup)
        seq = int(row["last_seq"]) + 1
        conn.execute(
            "INSERT INTO live_segment (live_session_id, seq, ts_start_ms,"
            " ts_end_ms, speaker_id, speaker_conf, label_state, local_label,"
            " text, lang, translation, device_id, audio_ref)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,NULL,?,?)",
            (live_session_id, seq, int(ts_start_ms), int(ts_end_ms),
             speaker_id or None, speaker_conf, label_state,
             local_label or None, text, lang or None,
             device_id or None, audio_ref or None))
        conn.execute(
            "INSERT INTO live_segment_fts (text, live_session_id, seq)"
            " VALUES (?,?,?)", (text, live_session_id, seq))
        conn.execute("UPDATE live_session SET last_seq=? WHERE id=?",
                     (seq, live_session_id))
        if speaker_id:
            _bump_speaker(conn, speaker_id, ts_end_ms - ts_start_ms)
        conn.commit()
    return {"live_session_id": live_session_id, "seq": seq,
            "ts_start_ms": int(ts_start_ms), "ts_end_ms": int(ts_end_ms),
            "speaker_id": speaker_id or None, "speaker_conf": speaker_conf,
            "label_state": label_state, "local_label": local_label or None,
            "text": text, "lang": lang or None, "translation": None,
            "device_id": device_id or None, "audio_ref": audio_ref or None}


def segments_after(live_session_id: str, after_seq: int = 0,
                   limit: int = 500) -> list:
    with connect() as conn:
        cur = conn.execute(
            "SELECT * FROM live_segment WHERE live_session_id=? AND seq>?"
            " ORDER BY seq LIMIT ?",
            (live_session_id, int(after_seq), int(limit)))
        return [dict(r) for r in cur.fetchall()]


def segment_range(live_session_id: str, ts_from_ms: int,
                  ts_to_ms: int, limit: int = 500) -> list:
    with connect() as conn:
        cur = conn.execute(
            "SELECT * FROM live_segment WHERE live_session_id=?"
            " AND ts_end_ms>=? AND ts_start_ms<=? ORDER BY seq LIMIT ?",
            (live_session_id, int(ts_from_ms), int(ts_to_ms), int(limit)))
        return [dict(r) for r in cur.fetchall()]


def set_translation(live_session_id: str, seq: int, translation: str) -> None:
    with connect() as conn:
        conn.execute(
            "UPDATE live_segment SET translation=? WHERE live_session_id=? AND seq=?",
            (translation, live_session_id, int(seq)))
        conn.commit()


def set_transcription(live_session_id: str, seq: int, text: str,
                      lang: str = "") -> None:
    """Replace one utterance's words and the language they were spoken in.

    For the server's second opinion on language (see `api/live_language.py`):
    the phone transcribed Spanish with an English recogniser, so both the text
    and the `lang` on that row are wrong, and `lang` is what decides whether
    anything ever gets translated.

    The FTS row is rewritten too. It is a separate table populated at insert,
    so updating only `live_segment` would leave the search index holding the
    English spelling of a Spanish sentence — findable by the wrong words,
    unfindable by the right ones.
    """
    with connect() as conn:
        conn.execute(
            "UPDATE live_segment SET text=?, lang=? WHERE live_session_id=? AND seq=?",
            (text, lang or None, live_session_id, int(seq)))
        conn.execute(
            "DELETE FROM live_segment_fts WHERE live_session_id=? AND seq=?",
            (live_session_id, int(seq)))
        conn.execute(
            "INSERT INTO live_segment_fts (text, live_session_id, seq)"
            " VALUES (?,?,?)", (text, live_session_id, int(seq)))
        conn.commit()


def search_segments(query: str, limit: int = 40,
                    live_session_id: str = "") -> list:
    """Full-text search over utterances, newest first."""
    if not (query or "").strip():
        return []
    sql = ("SELECT s.* FROM live_segment_fts f"
           " JOIN live_segment s ON s.live_session_id=f.live_session_id"
           "  AND s.seq=f.seq"
           " WHERE live_segment_fts MATCH ?")
    args: list = [query]
    if live_session_id:
        sql += " AND s.live_session_id=?"
        args.append(live_session_id)
    sql += " ORDER BY s.ts_start_ms DESC LIMIT ?"
    args.append(int(limit))
    with connect() as conn:
        try:
            cur = conn.execute(sql, args)
        except sqlite3.OperationalError:
            # A malformed FTS query (stray quote, bare NEAR) must not 500 the
            # caller — an empty result is the honest answer.
            return []
        return [dict(r) for r in cur.fetchall()]


# ── speakers ───────────────────────────────────────────────────────────────


# How much each voice actually said, derived from the segments themselves.
# `speaker.segment_count`/`speech_ms` used to be maintained by hand in three
# places; `assign_speaker` never debited the speaker it took a segment FROM, so
# a reassignment (the authority lane's normal output) left a ghost holding time
# it no longer owned, and `merge_speakers` then added that ghost's totals to the
# survivor. Deriving on read means there is one source of truth: the rows.
_SPEAKER_TOTALS = """
    LEFT JOIN (SELECT speaker_id,
                      COUNT(*) AS n,
                      COALESCE(SUM(ts_end_ms-ts_start_ms),0) AS ms
               FROM live_segment WHERE speaker_id IS NOT NULL
               GROUP BY speaker_id) t ON t.speaker_id = speaker.id
"""
_SPEAKER_SELECT = (
    "SELECT speaker.id, speaker.kind, speaker.name, speaker.created_at,"
    " speaker.last_heard_at, COALESCE(t.n,0) AS segment_count,"
    " COALESCE(t.ms,0) AS speech_ms FROM speaker" + _SPEAKER_TOTALS)


def _bump_speaker(conn: sqlite3.Connection, speaker_id: str,
                  speech_ms: int) -> None:
    """Only `last_heard_at` is stored; the totals are derived (see above)."""
    conn.execute("UPDATE speaker SET last_heard_at=? WHERE id=?",
                 (time.time(), speaker_id))


def create_speaker(kind: str = "other", name: str = "") -> dict:
    sid = uuid.uuid4().hex
    now = time.time()
    with connect() as conn:
        conn.execute(
            "INSERT INTO speaker (id, kind, name, created_at, last_heard_at)"
            " VALUES (?,?,?,?,?)", (sid, kind, name or None, now, now))
        conn.commit()
    return {"id": sid, "kind": kind, "name": name or None, "created_at": now,
            "last_heard_at": now, "segment_count": 0, "speech_ms": 0}


def rename_speaker(speaker_id: str, name: str) -> None:
    """Rename a voice. The id never changes, so history follows automatically."""
    with connect() as conn:
        conn.execute("UPDATE speaker SET name=? WHERE id=?",
                     (name or None, speaker_id))
        conn.commit()


def list_speakers() -> list:
    with connect() as conn:
        cur = conn.execute(
            _SPEAKER_SELECT + " ORDER BY speech_ms DESC, speaker.created_at")
        return [dict(r) for r in cur.fetchall()]


def get_speaker(speaker_id: str) -> Optional[dict]:
    with connect() as conn:
        cur = conn.execute(_SPEAKER_SELECT + " WHERE speaker.id=?",
                           (speaker_id,))
        return _row_to_dict(cur.fetchone())


def speaker_samples(speaker_id: str, limit: int = 5) -> list:
    """A few things this voice said, for the naming UI."""
    with connect() as conn:
        cur = conn.execute(
            "SELECT live_session_id, seq, ts_start_ms, text FROM live_segment"
            " WHERE speaker_id=? ORDER BY ts_start_ms DESC LIMIT ?",
            (speaker_id, int(limit)))
        return [dict(r) for r in cur.fetchall()]


SPEAKER_LINES_MAX = 200


def speaker_lines(speaker_id: str, *, before: Optional[tuple] = None,
                  limit: int = 50) -> tuple:
    """Everything a voice has said, newest first, one page at a time.

    `before` is the previous page's last line — (epoch ms, session, seq) — and
    rows strictly before it come next, so pages never overlap or skip even when
    two sessions have a line at the same millisecond. Returns (lines, the cursor
    for the next page or None, how many lines this voice has in all).
    """
    limit = max(1, min(int(limit), SPEAKER_LINES_MAX))
    at = "CAST(ROUND(s.started_at * 1000) AS INTEGER) + g.ts_start_ms"
    where, args = "g.speaker_id=?", [speaker_id]
    if before is not None:
        where += f" AND ({at}, g.live_session_id, g.seq) < (?, ?, ?)"
        args += [int(before[0]), str(before[1]), int(before[2])]
    with connect() as conn:
        total = conn.execute("SELECT COUNT(*) FROM live_segment WHERE speaker_id=?",
                             (speaker_id,)).fetchone()[0]
        rows = conn.execute(
            "SELECT g.live_session_id, g.seq, g.ts_start_ms, g.ts_end_ms, g.text, g.lang,"
            f" g.translation, s.title AS session_title, {at} AS at_ms"
            " FROM live_segment g JOIN live_session s ON s.id = g.live_session_id"
            f" WHERE {where} ORDER BY at_ms DESC, g.live_session_id DESC, g.seq DESC LIMIT ?",
            (*args, limit + 1)).fetchall()
    lines = [dict(r) for r in rows[:limit]]
    after = None
    if len(rows) > limit:
        last = lines[-1]
        after = (int(last["at_ms"]), str(last["live_session_id"]), int(last["seq"]))
    for line in lines:
        line["at"] = line.pop("at_ms") / 1000.0
    return lines, after, int(total or 0)


def merge_speakers(from_id: str, into_id: str) -> int:
    """Two clusters turned out to be one person. Returns segments relabelled.

    The surviving row is `into_id`, which is what makes a merge safe for
    clients: they relabel in place, and a name already given to `into_id` stays
    put.
    """
    if from_id == into_id:
        return 0
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        # Merging into an id that does not exist relabels the segments onto a
        # dangling speaker and deletes the only row that could name them: the
        # utterances become unnameable and their speech time vanishes from the
        # storage panel. Refuse instead.
        if conn.execute("SELECT 1 FROM speaker WHERE id=?",
                        (into_id,)).fetchone() is None:
            conn.rollback()
            raise KeyError(f"no such speaker to merge into: {into_id!r}")
        cur = conn.execute(
            "UPDATE live_segment SET speaker_id=? WHERE speaker_id=?",
            (into_id, from_id))
        moved = cur.rowcount or 0
        conn.execute("UPDATE speaker_embedding SET speaker_id=? WHERE speaker_id=?",
                     (into_id, from_id))
        gone = conn.execute("SELECT name FROM speaker WHERE id=?",
                            (from_id,)).fetchone()
        if gone is not None:
            # Keep a name the user typed on the losing row if the winner has none.
            if gone["name"]:
                conn.execute(
                    "UPDATE speaker SET name=COALESCE(name,?) WHERE id=?",
                    (gone["name"], into_id))
            conn.execute("DELETE FROM speaker WHERE id=?", (from_id,))
        conn.commit()
    return moved


def assign_speaker(live_session_id: str, seq: int, speaker_id: str,
                   conf: Optional[float] = None,
                   label_state: str = LABEL_CONFIRMED) -> None:
    """Resolve a segment to a canonical speaker (the authority lane's output)."""
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT speaker_id, ts_start_ms, ts_end_ms FROM live_segment"
            " WHERE live_session_id=? AND seq=?",
            (live_session_id, int(seq))).fetchone()
        if row is None:
            conn.rollback()
            return
        conn.execute(
            "UPDATE live_segment SET speaker_id=?, speaker_conf=?,"
            " label_state=? WHERE live_session_id=? AND seq=?",
            (speaker_id, conf, label_state, live_session_id, int(seq)))
        if row["speaker_id"] != speaker_id:
            _bump_speaker(conn, speaker_id,
                          int(row["ts_end_ms"]) - int(row["ts_start_ms"]))
        conn.commit()


def add_embedding(speaker_id: str, vec: Iterable[float], model: str,
                  from_segment: str = "") -> str:
    """Store one exemplar. Several per speaker is the point — identification
    improves as a voice is heard more."""
    blob = pack_vector(vec)
    eid = uuid.uuid4().hex
    with connect() as conn:
        conn.execute(
            "INSERT INTO speaker_embedding (id, speaker_id, vec, model,"
            " from_segment, created_at) VALUES (?,?,?,?,?,?)",
            (eid, speaker_id, blob, model, from_segment or None, time.time()))
        conn.commit()
    return eid


def embeddings_for_model(model: str) -> list:
    """Every stored exemplar for one model id, for identification.

    Filtering by model is what stops a vector from one checkpoint being compared
    against another's — that comparison is meaningless, not merely imprecise.
    """
    with connect() as conn:
        cur = conn.execute(
            "SELECT speaker_id, vec FROM speaker_embedding WHERE model=?",
            (model,))
        return [{"speaker_id": r["speaker_id"], "vec": unpack_vector(r["vec"])}
                for r in cur.fetchall()]


def pack_vector(vec: Iterable[float]) -> bytes:
    values = [float(v) for v in vec]
    return struct.pack(f"<{len(values)}f", *values)


def unpack_vector(blob: bytes) -> list:
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob[:n * 4]))


# ── digests ────────────────────────────────────────────────────────────────


def add_digest(live_session_id: str, *, seq_from: int, seq_to: int,
               summary: str, topics=None, speaker_ids=None, actions=None,
               ts_start_ms: int = 0, ts_end_ms: int = 0, model: str = "",
               embedding: Optional[Iterable[float]] = None,
               scope: str = "window") -> dict:
    did = uuid.uuid4().hex
    now = time.time()
    topics_json = json.dumps(list(topics or []))
    with connect() as conn:
        conn.execute(
            "INSERT INTO live_digest (id, live_session_id, seq_from, seq_to,"
            " ts_start_ms, ts_end_ms, summary, topics, speaker_ids, actions,"
            " model, created_at, embedding, scope)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (did, live_session_id, int(seq_from), int(seq_to),
             int(ts_start_ms), int(ts_end_ms), summary, topics_json,
             json.dumps(list(speaker_ids or [])),
             json.dumps(list(actions or [])), model or None, now,
             pack_vector(embedding) if embedding is not None else None, scope))
        conn.execute(
            "INSERT INTO live_digest_fts (summary, topics, id, live_session_id)"
            " VALUES (?,?,?,?)", (summary, topics_json, did, live_session_id))
        conn.commit()
    return {"id": did, "live_session_id": live_session_id,
            "seq_from": int(seq_from), "seq_to": int(seq_to),
            "summary": summary, "created_at": now, "scope": scope}


def get_digest(digest_id: str) -> Optional[dict]:
    """One digest by id — how an insight recovers the seq range of its window."""
    if not digest_id:
        return None
    with connect() as conn:
        cur = conn.execute("SELECT * FROM live_digest WHERE id=?", (digest_id,))
        return _row_to_dict(cur.fetchone())


# ── insights ───────────────────────────────────────────────────────────────


def add_insight(live_session_id: str, *, kind: str, text: str,
                seq_from: Optional[int] = None, seq_to: Optional[int] = None,
                anchor_seq: Optional[int] = None,
                scope: str = "", verdict: str = "", sources=None,
                digest_id: str = "", created_at: Optional[float] = None) -> dict:
    """Record one watcher note so it can be fetched back, not just broadcast."""
    iid = uuid.uuid4().hex
    now = float(created_at or time.time())
    row = {
        "id": iid, "live_session_id": live_session_id, "kind": kind or "monitor",
        "text": text, "seq_from": seq_from, "seq_to": seq_to,
        "anchor_seq": anchor_seq,
        "scope": scope or None, "verdict": verdict or None,
        "sources": json.dumps(list(sources)) if sources else None,
        "digest_id": digest_id or None, "created_at": now,
    }
    with connect() as conn:
        conn.execute(
            "INSERT INTO live_insight (id, live_session_id, kind, text,"
            " seq_from, seq_to, anchor_seq, scope, verdict, sources, digest_id,"
            " created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (iid, live_session_id, row["kind"], text, seq_from, seq_to,
             anchor_seq, row["scope"], row["verdict"], row["sources"],
             row["digest_id"], now))
        conn.commit()
    row["sources"] = list(sources) if sources else []
    return row


def insights_for_session(live_session_id: str, after_seq: int = 0,
                         limit: int = 200) -> list:
    """Notes for a session, oldest first.

    `after_seq` filters on `seq_to` so it lines up with the transcript's own
    cursor — a client resuming from `after_seq` gets the segments it missed and
    the notes about them in one coherent set. An insight with no `seq_to` is
    never filtered out: it belongs to the session rather than to a position.
    """
    with connect() as conn:
        cur = conn.execute(
            "SELECT * FROM live_insight WHERE live_session_id=?"
            " AND (seq_to IS NULL OR seq_to > ?)"
            " ORDER BY created_at LIMIT ?",
            (live_session_id, int(after_seq), int(limit)))
        rows = []
        for row in cur.fetchall():
            item = dict(row)
            try:
                item["sources"] = json.loads(item["sources"]) if item["sources"] else []
            except (TypeError, ValueError):
                item["sources"] = []
            rows.append(item)
        return rows


def search_digests(query: str, limit: int = 20) -> list:
    """Coarse retrieval: which window is worth reading."""
    if not (query or "").strip():
        return []
    with connect() as conn:
        try:
            cur = conn.execute(
                "SELECT d.* FROM live_digest_fts f"
                " JOIN live_digest d ON d.id=f.id"
                " WHERE live_digest_fts MATCH ?"
                " ORDER BY d.created_at DESC LIMIT ?", (query, int(limit)))
        except sqlite3.OperationalError:
            return []
        return [dict(r) for r in cur.fetchall()]


def digests_for_session(live_session_id: str) -> list:
    with connect() as conn:
        cur = conn.execute(
            "SELECT * FROM live_digest WHERE live_session_id=? ORDER BY seq_from",
            (live_session_id,))
        return [dict(r) for r in cur.fetchall()]


def session_text_stats(live_session_id: str) -> dict:
    """How much transcript a session has accumulated.

    Drives session rollover: a live session keeps growing until its transcript
    reaches a share of the model's context window, rather than starting a new
    one every time the user taps Record — which produced nine chats in half an
    hour.

    `est_tokens` is an ESTIMATE from character count (the usual ~4 chars per
    token). Rollover only needs the right order of magnitude, and counting
    exactly would mean running a tokeniser over the whole transcript on every
    handshake.
    """
    with connect() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(LENGTH(text)),0) AS chars"
            " FROM live_segment WHERE live_session_id=?",
            (live_session_id,)).fetchone()
    chars = int(row["chars"])
    return {"segments": int(row["n"]), "chars": chars,
            "est_tokens": chars // 4}


def last_digest_seq(live_session_id: str) -> int:
    """Where the previous window stopped, so the next one knows its start."""
    with connect() as conn:
        cur = conn.execute(
            "SELECT MAX(seq_to) AS s FROM live_digest WHERE live_session_id=?"
            " AND scope='window'", (live_session_id,))
        row = cur.fetchone()
        return int(row["s"] or 0)


# ── audio ──────────────────────────────────────────────────────────────────


_SESSION_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def _safe_session_dir(live_session_id: str) -> Path:
    """The audio directory for a session, or a refusal.

    Session ids reach this from request bodies. `Path(root) / "/etc"` discards
    the root entirely and `".."` climbs out, so an unchecked id turns a delete
    into an rmdir anywhere on the filesystem — demonstrated, not theoretical.
    Ids are uuid4 hex everywhere they are minted, so anything else is a bug or
    an attack and is refused rather than sanitised.
    """
    if not _SESSION_ID_RE.match(live_session_id or ""):
        raise ValueError(f"unsafe live session id: {live_session_id!r}")
    root = _audio_root()
    d = root / live_session_id
    if d.resolve().parent != root.resolve():
        raise ValueError(f"live session id escapes the audio root: {live_session_id!r}")
    return d


def audio_dir(live_session_id: str) -> Path:
    d = _safe_session_dir(live_session_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


# SQLite stores signed 64-bit integers and raises OverflowError on anything
# wider. A client's clock is not trustworthy enough to hand straight to it.
_MAX_SQLITE_INT = (1 << 63) - 1


def _storable_ms(raw, label: str, live_session_id: str) -> int:
    """A timestamp SQLite will accept, whatever the caller believed.

    Callers already normalise timestamps, and this is still worth having: the
    row is the audio file's ONLY handle. When this insert raised, the chunk was
    written to disk and nothing knew it existed — invisible to the storage
    panel, unreachable by every delete path, and unreadable by identification.
    Losing a timestamp costs one chunk's position; losing the row costs the
    chunk. Observed in production as `OverflowError: Python int too large to
    convert to SQLite INTEGER`, twice, at a session end.
    """
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = 0
    if 0 <= value <= _MAX_SQLITE_INT:
        return value
    logger.warning("live: %s=%r is not a storable timestamp on %s; "
                   "registering the chunk without it", label, raw,
                   live_session_id[:8] or "?")
    return 0


def register_audio(live_session_id: str, path, *, codec: str = "opus",
                   ts0_ms: int = 0, ts1_ms: int = 0,
                   device_id: str = "") -> dict:
    aid = uuid.uuid4().hex
    ts0_ms = _storable_ms(ts0_ms, "ts0_ms", live_session_id)
    ts1_ms = _storable_ms(ts1_ms, "ts1_ms", live_session_id)
    try:
        size = int(Path(path).stat().st_size)
    except OSError:
        size = 0
    with connect() as conn:
        # OR IGNORE: the startup sweep can race a roll, and a client whose
        # timestamps make the writer reuse a stem would otherwise register the
        # same file twice and double-count its bytes.
        conn.execute(
            "INSERT OR IGNORE INTO live_audio (id, live_session_id, path, codec,"
            " ts0_ms, ts1_ms, bytes, device_id) VALUES (?,?,?,?,?,?,?,?)",
            (aid, live_session_id, str(path), codec, int(ts0_ms), int(ts1_ms),
             size, device_id or None))
        conn.commit()
    return {"id": aid, "path": str(path), "bytes": size}


def sweep_orphan_audio() -> dict:
    """Adopt audio files on disk that no `live_audio` row knows about.

    A chunk is registered when it is rolled, so a crash mid-chunk leaves a real
    file with no row: invisible to `storage_summary` and missed by
    `delete_session`'s unlink, which means "delete this day" would silently
    leave audio behind. Registering at open instead would pin `bytes=0` for the
    chunk's whole life, so the recovery belongs here, at startup.

    Timestamps are unknown for an adopted file, so it is registered with the
    session's own span left at 0 and a codec of "unknown" rather than a guess.
    `delete_audio_with_speaker` matches chunks by time overlap and will not
    match these — deliberately, since deleting audio we cannot place would be
    worse than leaving it for the per-session delete to catch.
    """
    root = _audio_root()
    if not root.exists():
        return {"adopted": 0, "bytes": 0}
    adopted, total = 0, 0
    with connect() as conn:
        known = {r["path"] for r in conn.execute("SELECT path FROM live_audio")}
        sessions = {r["id"] for r in conn.execute("SELECT id FROM live_session")}
        for session_dir in sorted(root.iterdir()):
            if not session_dir.is_dir() or session_dir.name not in sessions:
                continue
            for f in sorted(session_dir.iterdir()):
                if not f.is_file() or str(f) in known:
                    continue
                try:
                    size = int(f.stat().st_size)
                except OSError:
                    continue
                conn.execute(
                    "INSERT OR IGNORE INTO live_audio (id, live_session_id,"
                    " path, codec, ts0_ms, ts1_ms, bytes, device_id)"
                    " VALUES (?,?,?,'unknown',0,0,?,NULL)",
                    (uuid.uuid4().hex, session_dir.name, str(f), size))
                adopted += 1
                total += size
        conn.commit()
    return {"adopted": adopted, "bytes": total}


def audio_chunks(live_session_id: str) -> list:
    with connect() as conn:
        cur = conn.execute(
            "SELECT * FROM live_audio WHERE live_session_id=? ORDER BY ts0_ms",
            (live_session_id,))
        return [dict(r) for r in cur.fetchall()]


# ── storage accounting ─────────────────────────────────────────────────────


def storage_summary() -> dict:
    """What is on disk, and roughly whose it is.

    Per-speaker bytes are an ESTIMATE and labelled as such. One chunk holds
    everyone who spoke during it, so bytes are attributed in proportion to
    speech time rather than measured. A precise-looking number here would be a
    lie about what the file contains.
    """
    with connect() as conn:
        total = conn.execute(
            "SELECT COALESCE(SUM(bytes),0) AS b, COUNT(*) AS n FROM live_audio"
        ).fetchone()
        per_session = [dict(r) for r in conn.execute(
            "SELECT a.live_session_id, COALESCE(SUM(a.bytes),0) AS bytes,"
            " COUNT(*) AS chunks, s.title, s.started_at, s.source_label"
            " FROM live_audio a LEFT JOIN live_session s ON s.id=a.live_session_id"
            " GROUP BY a.live_session_id ORDER BY bytes DESC").fetchall()]
        per_day = [dict(r) for r in conn.execute(
            "SELECT date(s.started_at,'unixepoch','localtime') AS day,"
            " COALESCE(SUM(a.bytes),0) AS bytes"
            " FROM live_audio a JOIN live_session s ON s.id=a.live_session_id"
            " GROUP BY day ORDER BY day DESC").fetchall()]
        speakers = [dict(r) for r in conn.execute(
            _SPEAKER_SELECT).fetchall()]
        # The denominator has to be ALL recorded speech, not just the labelled
        # part. Until on-device identification lands, most segments carry a
        # provisional label with speaker_id NULL — dividing by labelled speech
        # alone attributed a whole 2-hour recording to whoever happened to be
        # identified for ten seconds of it.
        spoken = conn.execute(
            "SELECT COALESCE(SUM(ts_end_ms-ts_start_ms),0) AS ms,"
            " COALESCE(SUM(CASE WHEN speaker_id IS NULL"
            "                   THEN ts_end_ms-ts_start_ms ELSE 0 END),0) AS unknown_ms"
            " FROM live_segment").fetchone()

    total_bytes = int(total["b"])
    total_speech = int(spoken["ms"])
    for s in speakers:
        share = (int(s["speech_ms"] or 0) / total_speech) if total_speech else 0.0
        s["approx_bytes"] = int(round(total_bytes * share))
    speakers.sort(key=lambda s: s["approx_bytes"], reverse=True)

    unknown_ms = int(spoken["unknown_ms"])
    unattributed = {
        "speech_ms": unknown_ms,
        "approx_bytes": int(round(total_bytes * (unknown_ms / total_speech)))
        if total_speech else total_bytes,
    }

    return {"total_bytes": total_bytes, "chunks": int(total["n"]),
            "per_session": per_session, "per_day": per_day,
            "per_speaker_approx": speakers,
            "unattributed": unattributed,
            "note": "per-speaker bytes are estimated from speech time; one "
                    "audio chunk contains every voice heard during it, and "
                    "speech from a voice not yet identified is reported as "
                    "unattributed rather than shared out"}


# ── deletion ───────────────────────────────────────────────────────────────


def delete_session(live_session_id: str) -> dict:
    """Exact: this session's audio chunks, segments, digests and row."""
    removed_bytes = 0
    with connect() as conn:
        rows = conn.execute("SELECT path, bytes FROM live_audio"
                            " WHERE live_session_id=?",
                            (live_session_id,)).fetchall()
        for r in rows:
            removed_bytes += _unlink(r["path"], int(r["bytes"] or 0))
        conn.execute("DELETE FROM live_audio WHERE live_session_id=?",
                     (live_session_id,))
        conn.execute("DELETE FROM live_segment_fts WHERE live_session_id=?",
                     (live_session_id,))
        conn.execute("DELETE FROM live_segment WHERE live_session_id=?",
                     (live_session_id,))
        conn.execute("DELETE FROM live_digest_fts WHERE live_session_id=?",
                     (live_session_id,))
        conn.execute("DELETE FROM live_digest WHERE live_session_id=?",
                     (live_session_id,))
        conn.execute("DELETE FROM live_session WHERE id=?", (live_session_id,))
        conn.commit()
    try:
        _rmdir_quiet(_safe_session_dir(live_session_id))
    except ValueError:
        # The rows are already gone; refusing the directory is the whole point.
        pass
    _purge_freed_space()
    return {"deleted_session": live_session_id, "freed_bytes": removed_bytes}


def sessions_on_day(day: str) -> list:
    """Session ids started on one local calendar day ("YYYY-MM-DD").

    Local, not UTC, because the storage panel groups by the day the user
    remembers having the conversation.
    """
    with connect() as conn:
        cur = conn.execute(
            "SELECT id FROM live_session"
            " WHERE date(started_at,'unixepoch','localtime')=?", (day,))
        return [r["id"] for r in cur.fetchall()]


def delete_day(day: str) -> dict:
    """Exact: every session started on that local day, audio and transcript.

    §3.1 offers this next to per-session delete, and it is the one the storage
    panel's per-day rows need in order to be actionable rather than decorative.
    """
    freed, ids = 0, sessions_on_day(day)
    for sid in ids:
        freed += int(delete_session(sid)["freed_bytes"])
    return {"day": day, "sessions_deleted": len(ids), "freed_bytes": freed}


def forget_speaker(speaker_id: str) -> dict:
    """Drop a voiceprint, that voice's transcript rows, and any digest naming
    them. Audio is KEPT.

    The surgical option: this person's words and voiceprint go, but the
    recordings they appear in stay, because those recordings contain other
    people too.

    Digests have to go with them. The window-summary prompt deliberately keeps
    names and specifics so the archive stays searchable, which means a digest
    covering this speaker is a second, fully indexed copy of what they said —
    deleting their segments while leaving the summary would make "forget this
    voice" a lie. The surviving speakers' raw segments are untouched, so a
    window can be summarised again later if it matters.
    """
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        segs = conn.execute(
            "SELECT live_session_id, seq FROM live_segment WHERE speaker_id=?",
            (speaker_id,)).fetchall()
        for s in segs:
            conn.execute(
                "DELETE FROM live_segment_fts WHERE live_session_id=? AND seq=?",
                (s["live_session_id"], s["seq"]))
        conn.execute("DELETE FROM live_segment WHERE speaker_id=?", (speaker_id,))
        conn.execute("DELETE FROM speaker_embedding WHERE speaker_id=?",
                     (speaker_id,))
        conn.execute("DELETE FROM speaker WHERE id=?", (speaker_id,))
        # speaker_ids is a JSON array, so match the quoted id rather than a bare
        # substring: a bare LIKE would also hit an id that merely contains this
        # one as a prefix.
        needle = f'%"{speaker_id}"%'
        # Two predicates, because neither alone is enough. speaker_ids catches a
        # digest that recorded this voice; the seq range catches one that names
        # them in prose while their segments were still provisionally labelled
        # (speaker_id NULL), which is the common case before identification
        # confirms anyone.
        clauses = ["speaker_ids LIKE ?"]
        args: list = [needle]
        for row in segs:
            clauses.append(
                "(live_session_id=? AND seq_from<=? AND seq_to>=?)")
            args += [row["live_session_id"], row["seq"], row["seq"]]
        digests = conn.execute(
            "SELECT id FROM live_digest WHERE " + " OR ".join(clauses),
            args).fetchall()
        for d in digests:
            conn.execute("DELETE FROM live_digest_fts WHERE id=?", (d["id"],))
            conn.execute("DELETE FROM live_digest WHERE id=?", (d["id"],))
        conn.commit()
    _purge_freed_space()
    return {"forgot_speaker": speaker_id, "segments_removed": len(segs),
            "digests_removed": len(digests), "audio_kept": True}


def delete_audio_with_speaker(speaker_id: str) -> dict:
    """Coarse: delete every audio chunk this voice appears in.

    Deliberately blunt, and the UI says so: a chunk overlapping this speaker
    holds whoever else was talking, and they go with it. Transcript rows are
    left alone — the words are still true once the recording is gone.
    """
    freed = 0
    with connect() as conn:
        rows = conn.execute(
            "SELECT DISTINCT a.id, a.path, a.bytes FROM live_audio a"
            " JOIN live_segment s ON s.live_session_id=a.live_session_id"
            " WHERE s.speaker_id=? AND s.ts_end_ms>=a.ts0_ms"
            "   AND s.ts_start_ms<=a.ts1_ms", (speaker_id,)).fetchall()
        # Overlap needs both sides on one clock. A chunk with unknown times (an
        # adopted orphan) or a segment ingested without them matches nothing, so
        # the precise query can return zero while the voice is plainly on the
        # recording — a privacy deletion reporting success while deleting
        # nothing. Fall back to every chunk of every session this voice appears
        # in: blunter, and the dialog already warns that whole recordings go.
        imprecise = False
        if not rows:
            rows = conn.execute(
                "SELECT DISTINCT a.id, a.path, a.bytes FROM live_audio a"
                " WHERE a.live_session_id IN ("
                "   SELECT DISTINCT live_session_id FROM live_segment"
                "   WHERE speaker_id=?)", (speaker_id,)).fetchall()
            imprecise = bool(rows)
        for r in rows:
            freed += _unlink(r["path"], int(r["bytes"] or 0))
            conn.execute("DELETE FROM live_audio WHERE id=?", (r["id"],))
        conn.commit()
    _purge_freed_space()
    return {"speaker_id": speaker_id, "chunks_deleted": len(rows),
            "freed_bytes": freed, "whole_sessions": imprecise}


def _purge_freed_space() -> None:
    """Make a delete actually unreadable on disk, not merely unindexed.

    Measured, because the obvious answer is wrong: with `secure_delete=ON` and a
    VACUUM, a deleted utterance was STILL recoverable with `strings live.db`.
    Deleting an FTS5 row removes it from the content table but leaves its terms
    in the index b-tree until a merge, so the words persist. `rebuild`
    regenerates each index from its (already-correct) content table, and the
    VACUUM then reclaims and zeroes what that frees. Verified: the term is gone
    from the file afterwards.

    Only the explicit delete paths call this — rebuilding an index is far too
    expensive to do per utterance. VACUUM cannot run inside a transaction,
    hence the separate statement after the commit.
    """
    try:
        with connect() as conn:
            for table in ("live_segment_fts", "live_digest_fts"):
                conn.execute(f"INSERT INTO {table}({table}) VALUES('rebuild')")
            conn.commit()
            conn.execute("VACUUM")
    except sqlite3.Error:
        # A concurrent writer can block this. The rows are gone either way, so
        # the cost of failing is residue on disk until the next delete, not
        # data the user can still see through the app.
        logger.warning("live: could not purge freed space after a delete",
                       exc_info=True)


def _unlink(path: str, known_bytes: int) -> int:
    try:
        os.unlink(path)
        return known_bytes
    except OSError:
        return 0


def _rmdir_quiet(d: Path) -> None:
    try:
        d.rmdir()
    except OSError:
        pass
