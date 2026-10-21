"""jc_client.imessage_memory — what leaves the Mac, and when."""
import sqlite3

import pytest

import jc_client.imessage_memory as im
from jc_client import imessage_relay as relay

T0 = 1_760_918_520.0  # unix seconds


def _ns(unix):
    return int((unix - im.APPLE_EPOCH) * 1e9)


def _make_db(path):
    db = sqlite3.connect(path)
    db.executescript("""
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, handle_id INTEGER,
        date INTEGER, is_from_me INTEGER, item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
        cache_has_attachments INTEGER DEFAULT 0);
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, display_name TEXT, chat_identifier TEXT);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, mime_type TEXT, transfer_name TEXT);
    CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
    INSERT INTO handle VALUES (1, '+15105550000'), (2, 'mom@example.com');
    INSERT INTO chat VALUES (1, 'iMessage;-;+15105550000', 45, '', '+15105550000'),
                            (2, 'iMessage;+;chat99', 43, 'Family', 'chat99');
    INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2);
    INSERT INTO attachment VALUES (1, 'image/jpeg', 'IMG_1.jpg'), (2, 'application/pdf', 'lease.pdf');
    """)
    return db


def _add(db, rowid, chat, text, *, handle=1, me=0, ts=T0, assoc=0, att=()):
    db.execute("INSERT INTO message VALUES (?, ?, NULL, ?, ?, ?, 0, ?, ?)",
               (rowid, text, handle, _ns(ts), me, assoc, 1 if att else 0))
    db.execute("INSERT INTO chat_message_join VALUES (?, ?)", (chat, rowid))
    for a in att:
        db.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (rowid, a))
    db.commit()


@pytest.fixture(autouse=True)
def contacts(monkeypatch):
    monkeypatch.setattr(relay, "_book", {"5105550000": "Sam Lee", "mom@example.com": "Mom"})
    monkeypatch.setattr(relay, "_book_loaded_at", 1e18)


@pytest.fixture()
def chatdb(tmp_path):
    path = tmp_path / "chat.db"
    db = _make_db(path)
    yield path, db
    db.close()


def test_apple_ts_handles_ns_and_seconds():
    assert im.apple_ts(_ns(T0)) == pytest.approx(T0)
    assert im.apple_ts(T0 - im.APPLE_EPOCH) == pytest.approx(T0)


def test_reads_both_directions_with_chat_guid(chatdb):
    path, db = chatdb
    _add(db, 1, 1, "my address is 12 Oak St")
    _add(db, 2, 1, "thanks!", me=1, ts=T0 + 60)
    rows = im.read_messages(sqlite3.connect(path), after_rowid=0)
    assert [(r["rowid"], r["sender"], r["is_from_me"], r["guid"]) for r in rows] == [
        (1, "Sam Lee", False, "iMessage;-;+15105550000"), (2, "Me", True, "iMessage;-;+15105550000")]
    assert rows[0]["chat_name"] == "Sam Lee" and rows[0]["is_group"] is False
    assert rows[0]["participants"] == [{"handle": "+15105550000", "label": "Sam Lee"}]
    assert rows[1]["handle"] == ""
    assert rows[0]["ts"] == pytest.approx(T0)


def test_attachments_become_text_and_reactions_skipped(chatdb):
    path, db = chatdb
    _add(db, 1, 2, "￼", att=(1,))
    _add(db, 2, 2, "here's the lease", att=(2,), handle=2)
    _add(db, 3, 2, 'Loved "here\'s the lease"', assoc=2000)
    rows = im.read_messages(sqlite3.connect(path), after_rowid=0)
    assert [r["text"] for r in rows] == ["[photo]", "here's the lease [file: lease.pdf]"]
    assert rows[0]["chat_name"] == "Family" and rows[0]["is_group"] is True
    assert rows[1]["sender"] == "Mom"


def test_date_range_and_guid_filter(chatdb):
    path, db = chatdb
    _add(db, 1, 1, "old", ts=T0 - 86400)
    _add(db, 2, 1, "in range", ts=T0)
    _add(db, 3, 2, "other chat", ts=T0)
    rows = im.read_messages(sqlite3.connect(path), start=T0 - 60, end=T0 + 60,
                            guids=["iMessage;-;+15105550000"])
    assert [r["text"] for r in rows] == ["in range"]


@pytest.mark.parametrize("text", [
    "Your verification code is 123456",
    "123-456 is your Instagram code",
    "G-482913 is your Google verification code.",
    "Use 8812 to sign in to Uber",
    "Your one-time passcode: 77 41 is invalid, use 774190",
    "Your verification code is 123456.",
    "Your Uber code is 1234. Never share this code.",
    "Your code: 482913. Do not share it.",
    "Your login code is 554433, valid for 10 min",
    "Your Apple ID Code is: 123456. Do not share it with anyone.",
])
def test_is_code_message_catches_otps(text):
    assert im.is_code_message(text)


@pytest.mark.parametrize("text", [
    "My address is 4521 Oak St, Oakland 94611",
    "It was $1250 for the flights",
    "Dinner at 7:30? Table for 4",
    "Call me at 510-555-0000",
    "can you send me the code for the project when you can",
    "My address is 1234 Main St, zip code 94110",
    "the code review is due Oct 20, 2026",
    "let me log in tonight, meet at 1900 Broadway",
    "Sign up for the 5k, it's 12/14 at 8:30",
])
def test_is_code_message_keeps_addresses_and_prices(text):
    assert not im.is_code_message(text)


def test_allowed_default_and_skip():
    cfg = {"enabled": True, "chats": {"g-on": True, "one-off": False}, "skip": ["mom@example.com"]}
    one = {"guid": "new-1to1", "is_group": False, "handle": "+15105550000", "text": "hi", "participants": []}
    group = {"guid": "new-group", "is_group": True, "handle": "+15105550000", "text": "hi", "participants": []}
    assert im.allowed(one, cfg) and not im.allowed(group, cfg)
    assert im.allowed({**group, "guid": "g-on"}, cfg)
    assert not im.allowed({**one, "guid": "one-off"}, cfg)
    assert not im.allowed({**one, "handle": "Mom@example.com"}, cfg)
    assert not im.allowed({**group, "guid": "g-on", "participants": [{"handle": "mom@example.com"}]}, cfg)
    assert not im.allowed({**one, "text": "Your login code is 445566"}, cfg)
    assert not im.allowed(one, {**cfg, "enabled": False})


class FakeServer:
    def __init__(self, config, fail=False):
        self.config = config
        self.fail = fail
        self.posts = []

    def __call__(self, method, path, payload=None):
        if self.fail:
            return None
        if method == "GET":
            return self.config
        self.posts.append((path, {"device_id": "mac-1", **payload}))
        if path.endswith("/messages"):
            return {"ok": True, "accepted": len(payload["messages"]), "duplicate": 0}
        return {"ok": True}


def _memory(tmp_path, path, server):
    m = im.IMessageMemory(lambda: "http://x", device_id=lambda: "mac-1",
                          state_path=tmp_path / "state.json", db_path=path)
    m._request = server
    return m


def test_first_enable_starts_from_max_rowid(tmp_path, chatdb):
    path, db = chatdb
    _add(db, 1, 1, "before he switched it on")
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": None})
    m = _memory(tmp_path, path, server)
    m.tick(now=T0)
    assert not [p for p in server.posts if p[0].endswith("/messages")]
    _add(db, 2, 1, "after")
    m.tick(now=T0 + 1)
    (msgs,) = [p[1]["messages"] for p in server.posts if p[0].endswith("/messages")]
    assert [x["text"] for x in msgs] == ["after"]


def test_cursor_advances_only_after_ack(tmp_path, chatdb):
    path, db = chatdb
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": None})
    m = _memory(tmp_path, path, server)
    m.tick(now=T0)
    _add(db, 1, 1, "hello")
    server.fail = True
    m.tick(now=T0 + 1)
    assert m._load_state()["cursor"] == 0
    server.fail = False
    m.tick(now=T0 + 2)
    assert m._load_state()["cursor"] == 1
    assert any(p[0].endswith("/messages") for p in server.posts)


def test_disabled_clears_cursor(tmp_path, chatdb):
    path, db = chatdb
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": None})
    m = _memory(tmp_path, path, server)
    m.tick(now=T0)
    server.config = {"enabled": False}
    m.refresh()
    m.tick(now=T0 + 1)
    assert m._load_state()["cursor"] is None


def test_backfill_reads_range_and_reports_done(tmp_path, chatdb):
    path, db = chatdb
    _add(db, 1, 1, "two days ago", ts=T0 - 2 * 86400)
    _add(db, 2, 1, "yesterday", ts=T0 - 86400)
    _add(db, 3, 2, "group yesterday", ts=T0 - 86400)
    job = {"id": "job1", "start": T0 - 86400 - 60, "end": T0, "chats": None, "status": "pending"}
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": job})
    m = _memory(tmp_path, path, server)
    m.tick(now=T0)
    batches = [p[1] for p in server.posts if p[0].endswith("/messages")]
    assert [x["text"] for b in batches for x in b["messages"]] == ["yesterday"]  # group off by default
    assert batches[0]["job_id"] == "job1"
    assert ("/api/imessage-memory/backfill/progress", {"device_id": "mac-1", "id": "job1", "done": True}) \
        in server.posts
    server.posts.clear()
    m.tick(now=T0 + 1)  # finished: not run again
    assert not any(p[0].endswith("/progress") for p in server.posts)


def test_request_adds_device_id(tmp_path, monkeypatch):
    sent = {}

    class Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"ok": true}'

    def fake_urlopen(req, timeout):
        sent["body"], sent["url"] = req.data, req.full_url
        return Resp()

    monkeypatch.setattr(im.urllib.request, "urlopen", fake_urlopen)
    m = im.IMessageMemory(lambda: "http://x", device_id=lambda: "mac-1", state_path=tmp_path / "s.json")
    assert m._post("/api/imessage-memory/chats", {"chats": []}) == {"ok": True}
    assert b'"device_id": "mac-1"' in sent["body"] and sent["url"] == "http://x/api/imessage-memory/chats"


def test_offline_start_keeps_the_cursor(tmp_path, chatdb):
    """No answer from the server is not "switched off": the cursor survives."""
    path, db = chatdb
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": None}, fail=True)
    m = _memory(tmp_path, path, server)
    m._save_state({"cursor": 7, "finished_jobs": [], "backfill_after": {}})
    m.tick(now=T0)
    assert m._load_state()["cursor"] == 7


def test_empty_rows_dont_stall_the_cursor(tmp_path, chatdb, monkeypatch):
    path, db = chatdb
    monkeypatch.setattr(im, "BATCH", 3)
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": None})
    m = _memory(tmp_path, path, server)
    m.tick(now=T0)
    for rowid in (1, 2, 3):
        _add(db, rowid, 1, "")          # unsent / undecodable: no text
    _add(db, 4, 1, "real one")
    m.tick(now=T0 + 1)
    sent = [x["text"] for p in server.posts if p[0].endswith("/messages") for x in p[1]["messages"]]
    assert sent == ["real one"] and m._load_state()["cursor"] == 4


def test_backfill_runs_past_empty_batches(tmp_path, chatdb, monkeypatch):
    path, db = chatdb
    monkeypatch.setattr(im, "BATCH", 3)
    for rowid in (1, 2, 3):
        _add(db, rowid, 1, "", ts=T0 - 100)
    _add(db, 4, 1, "after the gap", ts=T0 - 100)
    job = {"id": "j", "start": T0 - 1000, "end": T0, "chats": None}
    server = FakeServer({"enabled": True, "chats": {}, "skip": [], "backfill": job})
    _memory(tmp_path, path, server).tick(now=T0)
    sent = [x["text"] for p in server.posts if p[0].endswith("/messages") for x in p[1]["messages"]]
    assert sent == ["after the gap"]


def test_message_in_two_chats_not_split_at_batch_edge(chatdb):
    path, db = chatdb
    _add(db, 1, 1, "first")
    _add(db, 2, 1, "in both chats")
    db.execute("INSERT INTO chat_message_join VALUES (2, 2)")
    db.commit()
    rows, last = im.read_batch(sqlite3.connect(path), after_rowid=0, limit=2)
    assert [r["rowid"] for r in rows] == [1] and last == 1
    rows, last = im.read_batch(sqlite3.connect(path), after_rowid=1, limit=2)
    assert sorted(r["guid"] for r in rows) == ["iMessage;+;chat99", "iMessage;-;+15105550000"]


def test_history_older_than_switch_on_is_not_sent_live(tmp_path, chatdb):
    path, db = chatdb
    server = FakeServer({"enabled": True, "enabled_at": T0, "chats": {}, "skip": [], "backfill": None})
    m = _memory(tmp_path, path, server)
    m.tick(now=T0)
    _add(db, 1, 1, "synced from iCloud, a year old", ts=T0 - 365 * 86400)
    _add(db, 2, 1, "new", ts=T0 + 5)
    m.tick(now=T0 + 10)
    sent = [x["text"] for p in server.posts if p[0].endswith("/messages") for x in p[1]["messages"]]
    assert sent == ["new"]


def test_chat_list_goes_up_while_off(tmp_path, chatdb):
    path, db = chatdb
    _add(db, 1, 1, "hi", ts=T0)
    server = FakeServer({"enabled": False})
    _memory(tmp_path, path, server).tick(now=T0 + 10)
    assert [p for p in server.posts if p[0].endswith("/chats")]
    assert not [p for p in server.posts if p[0].endswith("/messages")]
