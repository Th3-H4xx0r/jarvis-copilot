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


def _contact_name(handle: str, cache: dict[str, str]) -> str:
    """The contact's name for a phone number or email, when Contacts allows it."""
    if handle in cache:
        return cache[handle]
    name = handle
    try:
        import Contacts  # pyobjc; present in the tray's environment

        store = Contacts.CNContactStore.alloc().init()
        keys = [Contacts.CNContactGivenNameKey, Contacts.CNContactFamilyNameKey]
        if "@" in handle:
            pred = Contacts.CNContact.predicateForContactsMatchingEmailAddress_(handle)
        else:
            number = Contacts.CNPhoneNumber.phoneNumberWithStringValue_(handle)
            pred = Contacts.CNContact.predicateForContactsMatchingPhoneNumber_(number)
        found, _err = store.unifiedContactsMatchingPredicate_keysToFetch_error_(pred, keys, None)
        if found:
            c = found[0]
            full = f"{c.givenName()} {c.familyName()}".strip()
            if full:
                name = full
    except Exception:  # noqa: BLE001 - Contacts is a nicety, never a failure
        pass
    cache[handle] = name
    return name


class IMessageRelay:
    def __init__(self, api_origin) -> None:
        # Called lazily: the loopback proxy may not be up yet when the relay starts.
        self._api_origin = api_origin
        self._names: dict[str, str] = {}
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
                            self._send(_contact_name(handle or "", self._names) or "iMessage", message)
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
                                     headers={"Content-Type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=10).read()
        except Exception as exc:  # noqa: BLE001
            log.warning("iMessage relay post failed: %s", exc)
