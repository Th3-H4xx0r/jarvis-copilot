"""iMessage → Jarvis long-term memory (the Mac's half).

Reads his Messages database (``chat.db``, both directions) and uploads the
messages of the chats he lets Jarvis remember to ``/api/imessage-memory``; the
server turns each quiet conversation burst into memories. Filtering happens
HERE, before anything leaves the Mac: the switch, his chat picks (unset: 1:1 on,
group off), the skip list, and anything that looks like a one-time code.

Nothing from before he switches it on is sent unless he runs a backfill: the
first time it's seen enabled, the cursor starts at the newest message. The
cursor only moves after the server has the batch, so a sleeping or offline Mac
catches up later. Needs Full Disk Access, like the glasses relay.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
import time
import urllib.request
from pathlib import Path

from jc_client import imessage_relay as relay

log = logging.getLogger("jc_client.imessage_memory")

APPLE_EPOCH = 978307200  # 2001-01-01 in unix seconds
BATCH = 200
CONFIG_EVERY = 600.0
CHATS_EVERY = 3600.0
CHAT_LIST_DAYS = 365
CHAT_LIST_MAX = 500
WAKE_SECONDS = 15.0

_CODE_WORDS = re.compile(
    r"\b(code|codes|otp|passcode|pass code|verification|verify|2fa|two[- ]factor|one[- ]time|"
    r"security code|log ?in|sign ?in|authenticat\w*)\b", re.I)
_CODE_NUMBER = re.compile(r"(?<![\w$#.,:/])(?:G-)?(?:\d{3}[- ]\d{3}|\d{4,8})(?![\w.,:/%])")


def apple_ts(value) -> float:
    """Unix seconds for a chat.db ``date``: nanoseconds since 2001 on modern
    macOS, plain seconds on rows from old versions."""
    v = float(value or 0)
    if v > 1e14:
        v /= 1e9
    return v + APPLE_EPOCH


def _apple_ns(unix: float) -> int:
    return int((float(unix) - APPLE_EPOCH) * 1e9)


def is_code_message(text: str) -> bool:
    """A one-time code / login text: code wording next to a 4–8 digit code.
    Numbers on their own (addresses, prices, times) don't count."""
    t = text or ""
    return bool(_CODE_WORDS.search(t) and _CODE_NUMBER.search(t))


def normalize_handle(handle) -> str:
    """Matches the server's key: an email lowercased, a phone's last 10 digits."""
    h = str(handle or "").strip().lower()
    if "@" in h:
        return h
    digits = "".join(ch for ch in h if ch.isdigit())
    return digits[-10:] if digits else h


def contact_name(handle: str) -> str:
    """His Contacts name for a number or email, else ''."""
    if not handle:
        return ""
    if time.time() - relay._book_loaded_at > 600:
        relay._load_book()
    key = handle.strip().lower() if "@" in handle else relay._digits(handle)
    return relay._book.get(key, "")


def _attachment_text(mime: str, name: str) -> str:
    mime = (mime or "").lower()
    if mime.startswith("image/"):
        return "[photo]"
    if mime.startswith("video/"):
        return "[video]"
    if mime.startswith("audio/"):
        return "[voice memo]"
    return f"[file: {name}]" if name else "[file]"


_MESSAGE_SQL = """
SELECT m.ROWID AS rowid, m.date AS date, m.text AS text, m.attributedBody AS body,
       m.is_from_me AS is_from_me, IFNULL(m.cache_has_attachments, 0) AS has_att,
       h.id AS handle, c.ROWID AS chat_rowid, c.guid AS guid, c.style AS style,
       c.display_name AS display_name, c.chat_identifier AS chat_identifier
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
JOIN chat c ON c.ROWID = cmj.chat_id
LEFT JOIN handle h ON h.ROWID = m.handle_id
WHERE m.item_type = 0 AND IFNULL(m.associated_message_type, 0) = 0 AND {where}
ORDER BY m.ROWID
LIMIT ?
"""


def _participants(db, chat_rowid: int) -> list:
    rows = db.execute("SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id "
                      "WHERE chj.chat_id = ? ORDER BY h.id", (chat_rowid,)).fetchall()
    return [{"handle": r[0], "label": contact_name(r[0]) or r[0]} for r in rows if r[0]]


def _chat_name(display_name, participants: list, identifier: str) -> str:
    if display_name:
        return display_name
    labels = [p["label"] for p in participants]
    if len(labels) > 3:
        return ", ".join(labels[:3]) + f" +{len(labels) - 3}"
    return ", ".join(labels) or contact_name(identifier or "") or identifier or "Unknown"


def read_messages(db, *, after_rowid=None, start=None, end=None, guids=None, limit=500) -> list:
    """Messages (both directions) in ROWID order as upload dicts, each carrying
    its chat's details: guid, rowid, ts, sender, handle, is_from_me, text,
    chat_name, is_group, participants. Reactions and system rows are skipped;
    attachments become ``[photo]``-style text."""
    db.row_factory = sqlite3.Row
    where, args = ["1=1"], []
    if after_rowid is not None:
        where.append("m.ROWID > ?")
        args.append(int(after_rowid))
    if start is not None:
        where.append("m.date >= ?")
        args.append(_apple_ns(start))
    if end is not None:
        where.append("m.date <= ?")
        args.append(_apple_ns(end))
    if guids:
        where.append(f"c.guid IN ({','.join('?' * len(guids))})")
        args += list(guids)
    rows = db.execute(_MESSAGE_SQL.format(where=" AND ".join(where)), (*args, int(limit))).fetchall()
    chats: dict = {}
    out = []
    for r in rows:
        text = (r["text"] or relay.decode_attributed_body(r["body"]) or "").replace("￼", "").strip()
        if r["has_att"]:
            for mime, name in db.execute(
                    "SELECT a.mime_type, a.transfer_name FROM message_attachment_join maj "
                    "JOIN attachment a ON a.ROWID = maj.attachment_id WHERE maj.message_id = ?",
                    (r["rowid"],)).fetchall():
                text = (text + " " + _attachment_text(mime, name)).strip()
        if not text:
            continue
        if r["chat_rowid"] not in chats:
            people = _participants(db, r["chat_rowid"])
            chats[r["chat_rowid"]] = {
                "chat_name": _chat_name(r["display_name"], people, r["chat_identifier"]),
                "is_group": r["style"] == 43, "participants": people}
        handle = "" if r["is_from_me"] else (r["handle"] or "")
        out.append({"guid": r["guid"], "rowid": r["rowid"], "ts": apple_ts(r["date"]),
                    "sender": "Me" if r["is_from_me"] else (contact_name(handle) or handle or "Unknown"),
                    "handle": handle, "is_from_me": bool(r["is_from_me"]), "text": text[:4000],
                    **chats[r["chat_rowid"]]})
    return out


def list_chats(db, since_ts: float) -> list:
    """Chats with a message since ``since_ts``, newest first (at most 500)."""
    db.row_factory = sqlite3.Row
    rows = db.execute(
        "SELECT c.ROWID AS rowid, c.guid AS guid, c.style AS style, c.display_name AS display_name, "
        "c.chat_identifier AS chat_identifier, MAX(m.date) AS last FROM chat c "
        "JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID JOIN message m ON m.ROWID = cmj.message_id "
        "GROUP BY c.ROWID HAVING last >= ? ORDER BY last DESC LIMIT ?",
        (_apple_ns(since_ts), CHAT_LIST_MAX)).fetchall()
    out = []
    for r in rows:
        people = _participants(db, r["rowid"])
        out.append({"guid": r["guid"], "name": _chat_name(r["display_name"], people, r["chat_identifier"]),
                    "is_group": r["style"] == 43, "participants": people,
                    "last_message_at": apple_ts(r["last"])})
    return out


def allowed(message: dict, config: dict) -> bool:
    """Whether a message may leave the Mac: switched on, its chat picked (the
    server's word, else 1:1 on / group off), nobody in it on the skip list, and
    not a one-time code."""
    if not config.get("enabled"):
        return False
    skip = set(config.get("skip") or [])
    if normalize_handle(message.get("handle")) in skip:
        return False
    if any(normalize_handle(p.get("handle")) in skip for p in message.get("participants") or []):
        return False
    picks = config.get("chats") or {}
    if message.get("guid") in picks:
        if not picks[message["guid"]]:
            return False
    elif message.get("is_group"):
        return False
    return not is_code_message(message.get("text") or "")


class IMessageMemory:
    def __init__(self, api_origin, device_id=None, state_path=None, db_path=None) -> None:
        self._api_origin = api_origin          # callable → loopback proxy origin
        self._device_id = device_id or _device_id
        if state_path is None:
            from jc_client.logger import state_dir
            state_path = state_dir() / "imessage_memory.json"
        self._state_path = Path(state_path)
        self._db_path = Path(db_path or relay.DB_PATH)
        self._config: dict = {"enabled": False}
        self._config_at = 0.0
        self._chats_at = 0.0
        self._known_guids: set = set()
        self._refresh = threading.Event()
        self._warned = False

    # ── lifecycle ────────────────────────────────────────────────────────
    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True, name="imessage-memory").start()

    def refresh(self) -> None:
        """The server changed something: fetch the config on the next wake."""
        self._refresh.set()

    def _run(self) -> None:
        while True:
            try:
                self.tick()
            except Exception:
                log.exception("iMessage memory tick failed")
            relay.wait_for_write(WAKE_SECONDS, stop=self._refresh)

    # ── one pass ─────────────────────────────────────────────────────────
    def tick(self, now: float | None = None) -> None:
        now = time.time() if now is None else now
        if self._refresh.is_set() or now - self._config_at >= CONFIG_EVERY:
            self._refresh.clear()
            config = self._get("/api/imessage-memory/config")
            if isinstance(config, dict):
                self._config, self._config_at = config, now
                self._known_guids = set(config.get("chats") or {})
        state = self._load_state()
        if not self._config.get("enabled"):
            if state.get("cursor") is not None:
                state["cursor"] = None  # re-enabling starts from "now", not from here
                self._save_state(state)
            return
        db = self._open()
        if db is None:
            return
        try:
            if state.get("cursor") is None:
                state["cursor"] = db.execute("SELECT IFNULL(MAX(ROWID), 0) FROM message").fetchone()[0]
                self._save_state(state)
                log.info("iMessage memory on: remembering messages after %s", state["cursor"])
            self._upload_new(db, state)
            if now - self._chats_at >= CHATS_EVERY:
                self._upload_chats(db, now)
            job = self._config.get("backfill")
            if isinstance(job, dict) and job.get("id") not in state.get("finished_jobs", []):
                self._run_backfill(db, state, job)
        finally:
            db.close()

    def _upload_new(self, db, state: dict) -> None:
        while True:
            rows = read_messages(db, after_rowid=state["cursor"], limit=BATCH)
            if not rows:
                return
            if {m["guid"] for m in rows} - self._known_guids:
                self._chats_at = 0.0  # a chat the server hasn't seen: send the list next
                self._known_guids |= {m["guid"] for m in rows}
            send = [m for m in rows if allowed(m, self._config)]
            if send and self._post("/api/imessage-memory/messages", {"messages": send}) is None:
                return  # server unreachable: keep the cursor, retry next wake
            state["cursor"] = rows[-1]["rowid"]
            self._save_state(state)
            if len(rows) < BATCH:
                return

    def _upload_chats(self, db, now: float) -> None:
        chats = list_chats(db, now - CHAT_LIST_DAYS * 86400)
        if self._post("/api/imessage-memory/chats", {"chats": chats}) is not None:
            self._chats_at = now
            self._known_guids |= {c["guid"] for c in chats}

    def _run_backfill(self, db, state: dict, job: dict) -> None:
        """Upload a date range he asked for, resuming where an earlier pass
        stopped. Rechecks the config between batches so Stop is quick."""
        job_id = job["id"]
        after = state.setdefault("backfill_after", {}).get(job_id, 0)
        log.info("iMessage memory: backfill %s from message %s", job_id, after)
        while True:
            rows = read_messages(db, after_rowid=after, start=job.get("start"), end=job.get("end"),
                                 guids=job.get("chats") or None, limit=BATCH)
            if not rows:
                break
            send = [m for m in rows if allowed(m, self._config)]
            if send:
                resp = self._post("/api/imessage-memory/messages", {"job_id": job_id, "messages": send})
                if resp is None:
                    return  # try again on a later wake, from `after`
                if resp.get("stopped"):
                    self._finish(state, job_id)
                    return
            after = rows[-1]["rowid"]
            state["backfill_after"][job_id] = after
            self._save_state(state)
            if self._refresh.is_set():
                config = self._get("/api/imessage-memory/config")
                if isinstance(config, dict):
                    self._refresh.clear()
                    self._config = config
                    current = config.get("backfill") or {}
                    if current.get("id") != job_id:
                        self._finish(state, job_id)  # stopped or replaced
                        return
        if self._post("/api/imessage-memory/backfill/progress", {"id": job_id, "done": True}) is not None:
            self._finish(state, job_id)
            log.info("iMessage memory: backfill %s uploaded", job_id)

    def _finish(self, state: dict, job_id: str) -> None:
        state.setdefault("finished_jobs", []).append(job_id)
        state["finished_jobs"] = state["finished_jobs"][-50:]
        state.get("backfill_after", {}).pop(job_id, None)
        self._save_state(state)

    # ── plumbing ─────────────────────────────────────────────────────────
    def _open(self):
        try:
            return sqlite3.connect(f"file:{self._db_path}?mode=ro", uri=True, timeout=2)
        except sqlite3.Error as exc:
            if not self._warned:
                log.warning("iMessage memory idle: can't read %s (%s). Give the client Full Disk "
                            "Access in System Settings › Privacy & Security.", self._db_path, exc)
                self._warned = True
            return None

    def _load_state(self) -> dict:
        try:
            return json.loads(self._state_path.read_text())
        except (OSError, ValueError):
            return {"cursor": None, "finished_jobs": [], "backfill_after": {}}

    def _save_state(self, state: dict) -> None:
        try:
            self._state_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._state_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(state))
            tmp.replace(self._state_path)
        except OSError:
            log.warning("iMessage memory: could not save %s", self._state_path, exc_info=True)

    def _request(self, method: str, path: str, payload=None):
        origin = self._api_origin()
        if not origin:
            return None
        data = None
        if payload is not None:
            payload = {"device_id": self._device_id(), **payload}
            data = json.dumps(payload).encode()
        req = urllib.request.Request(origin + path, data=data, method=method,
                                     # Cloudflare refuses Python's default User-Agent (error 1010).
                                     headers={"Content-Type": "application/json",
                                              "User-Agent": "jc-client/0.1"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read() or b"{}")
        except Exception as exc:  # noqa: BLE001
            log.warning("iMessage memory %s %s failed: %s", method, path, exc)
            return None

    def _get(self, path: str):
        return self._request("GET", path)

    def _post(self, path: str, payload: dict):
        return self._request("POST", path, payload)


def _device_id() -> str:
    try:
        from jc_client import credentials
        return credentials.load().device_id or ""
    except Exception:
        return ""
