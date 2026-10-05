"""iMessage → glasses relay.

iOS doesn't share Messages notifications with Bluetooth accessories (the ESP32
relay sees every other app, never Messages), but the Mac receives every iMessage
too. This watches the Mac's Messages database for new incoming messages and posts
each one to the server's ``/api/devices/notify`` on the ``glasses`` channel; the
server pushes it to the phone, which puts it on the glasses' lens.

Reading ``~/Library/Messages/chat.db`` needs Full Disk Access for the process
running the client (System Settings › Privacy & Security › Full Disk Access).
Without it the relay logs one hint and stays idle.
"""

from __future__ import annotations

import json
import logging
import os
import select
import sqlite3
import threading
import time
import urllib.request
from pathlib import Path

log = logging.getLogger("jc_client.imessage")

DB_PATH = Path.home() / "Library" / "Messages" / "chat.db"
# A listener, not a poller: the thread sleeps on a kqueue file event and queries only
# when Messages writes the database (new rows land in chat.db-wal first). The timeout
# is a safety net for a missed event or a WAL file that was swapped out.
SAFETY_WAKE_SECONDS = 30.0

_QUERY = """
SELECT m.ROWID, m.text, m.attributedBody, h.id
FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID
WHERE m.ROWID > ? AND m.is_from_me = 0 AND m.item_type = 0
ORDER BY m.ROWID
"""


def decode_attributed_body(blob: bytes | None) -> str:
    """Pull the text out of an NSAttributedString typedstream (newer macOS stores
    message text here and leaves ``message.text`` NULL)."""
    if not blob:
        return ""
    i = blob.find(b"NSString")
    if i < 0:
        return ""
    j = blob.find(b"+", i)  # '+' marks the start of the string's length + bytes
    if j < 0 or j + 1 >= len(blob):
        return ""
    n = blob[j + 1]
    start = j + 2
    if n == 0x81:  # 16-bit little-endian length follows
        n = int.from_bytes(blob[j + 2:j + 4], "little")
        start = j + 4
    elif n == 0x82:  # 32-bit little-endian length follows
        n = int.from_bytes(blob[j + 2:j + 6], "little")
        start = j + 6
    return blob[start:start + n].decode("utf-8", "replace")


AB_SOURCES = Path.home() / "Library" / "Application Support" / "AddressBook"
_book: dict[str, str] = {}
_book_loaded_at = 0.0


def _digits(number: str) -> str:
    """Last 10 digits — matches "+1 (510) 777-3312" against "5107773312"."""
    d = "".join(ch for ch in number if ch.isdigit())
    return d[-10:]


def _load_book() -> None:
    """Read every name/phone/email from the Contacts databases. Full Disk Access
    (already needed for chat.db) covers them, so no Contacts permission prompt."""
    global _book, _book_loaded_at
    book: dict[str, str] = {}
    for db_path in AB_SOURCES.rglob("AddressBook-v22.abcddb"):
        try:
            db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
        except sqlite3.Error:
            continue
        try:
            names = {}
            for pk, first, last, org in db.execute(
                    "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD"):
                full = " ".join(x for x in (first, last) if x) or (org or "")
                if full:
                    names[pk] = full
            for owner, number in db.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
                if owner in names and number and _digits(number):
                    book[_digits(number)] = names[owner]
            for owner, address in db.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
                if owner in names and address:
                    book[address.strip().lower()] = names[owner]
        except sqlite3.Error:
            pass
        finally:
            db.close()
    _book, _book_loaded_at = book, time.time()
    log.info("iMessage relay: %d contact numbers/emails loaded", len(book))


def _sender_label(handle: str) -> str:
    """ "Jarvis (+15107773312)" when the number or email is a contact, else the handle."""
    if not handle:
        return "iMessage"
    if time.time() - _book_loaded_at > 600:  # pick up new contacts every 10 minutes
        _load_book()
    key = handle.strip().lower() if "@" in handle else _digits(handle)
    name = _book.get(key)
    return f"{name} ({handle})" if name else handle


class IMessageRelay:
    def __init__(self, api_origin) -> None:
        # Called lazily: the loopback proxy may not be up yet when the relay starts.
        self._api_origin = api_origin
        self._warned = False

    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True, name="imessage-relay").start()

    def _open(self) -> sqlite3.Connection | None:
        try:
            return sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=2)
        except sqlite3.Error as exc:
            if not self._warned:
                log.warning("iMessage relay idle: can't read %s (%s). Give the client Full Disk "
                            "Access in System Settings › Privacy & Security.", DB_PATH, exc)
                self._warned = True
            return None

    def _run(self) -> None:
        last = None
        while True:
            db = self._open()
            if db is not None:
                try:
                    if last is None:  # start from now: never replay old messages
                        last = db.execute("SELECT IFNULL(MAX(ROWID), 0) FROM message").fetchone()[0]
                        log.info("iMessage relay watching from message %s", last)
                    for rowid, text, body, handle in db.execute(_QUERY, (last,)).fetchall():
                        last = rowid
                        message = (text or decode_attributed_body(body)).strip()
                        if message:
                            self._send(_sender_label(handle or ""), message)
                except sqlite3.Error as exc:
                    if not self._warned:
                        log.warning("iMessage relay can't query Messages: %s", exc)
                        self._warned = True
                finally:
                    db.close()
            self._wait_for_write()

    def _wait_for_write(self) -> None:
        """Block until Messages writes chat.db (or its WAL), or the safety timeout."""
        fds = []
        try:
            kq = select.kqueue()
        except (AttributeError, OSError):
            time.sleep(SAFETY_WAKE_SECONDS)
            return
        try:
            events = []
            for path in (DB_PATH, DB_PATH.with_name("chat.db-wal")):
                try:
                    fd = os.open(path, os.O_EVTONLY if hasattr(os, "O_EVTONLY") else os.O_RDONLY)
                except OSError:
                    continue
                fds.append(fd)
                events.append(select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                            fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND
                                            | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME))
            if not events:
                time.sleep(SAFETY_WAKE_SECONDS)
                return
            kq.control(events, 1, SAFETY_WAKE_SECONDS)
            time.sleep(0.3)  # let Messages finish the transaction before reading
        finally:
            for fd in fds:
                os.close(fd)
            kq.close()

    def _send(self, sender: str, message: str) -> None:
        origin = self._api_origin()
        if not origin:
            return
        payload = json.dumps({"title": sender[:80], "body": message[:400],
                              "channel": "glasses", "app": "Messages"}).encode()
        req = urllib.request.Request(origin + "/api/devices/notify", data=payload,
                                     # Cloudflare refuses Python's default User-Agent (error 1010).
                                     headers={"Content-Type": "application/json",
                                              "User-Agent": "jc-client/0.1"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=10).read()
        except Exception as exc:  # noqa: BLE001
            log.warning("iMessage relay post failed: %s", exc)
