"""iMessage memory HTTP surface: his card and controls, the Mac's config and uploads."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.helpers as helpers  # noqa: E402
import api.imessage_memory as im  # noqa: E402
import api.imessage_memory_routes as routes  # noqa: E402
import api.imessage_memory_writer as writer  # noqa: E402

SAM = {"handle": "+15105550000", "label": "Sam Lee"}


@pytest.fixture()
def sent(monkeypatch):
    box: dict = {}

    def fake_j(handler, body, status=200):
        box["body"], box["status"] = body, status

    monkeypatch.setattr(helpers, "j", fake_j)
    return box


@pytest.fixture()
def st(tmp_path, monkeypatch):
    s = im.IMStore(tmp_path / "im.db")
    monkeypatch.setattr(routes, "store", lambda: s)
    monkeypatch.setattr(writer, "default_store", lambda: s)
    monkeypatch.setattr(writer, "memory_writer", lambda: None)
    monkeypatch.setattr(writer, "resolve_extraction_model", lambda agent: ("@x:y", "Default → model @x:y"))
    pushed = []
    monkeypatch.setattr(routes, "push_refresh", lambda store: pushed.append(True) or True)
    s.pushed = pushed
    return s


def _get(path):
    return routes.handle_get(None, urlparse(path))


def _post(path, body):
    return routes.handle_post(None, urlparse(path), body)


def _upload_chats(st):
    assert _post("/api/imessage-memory/chats", {"device_id": "mac-1", "chats": [
        {"guid": "one", "name": "Sam Lee", "is_group": False, "participants": [SAM],
         "last_message_at": 100.0},
        {"guid": "grp", "name": "Family", "is_group": True, "participants": [SAM],
         "last_message_at": 200.0}]})


def test_card_lists_chats_with_effective_pick(st, sent):
    _upload_chats(st)
    _post("/api/imessage-memory/chat", {"guid": "grp", "pick": True})
    assert _get("/api/imessage-memory")
    card = sent["body"]
    assert [c["guid"] for c in card["chats"]] == ["grp", "one"]
    assert [c["effective"] for c in card["chats"]] == [True, True]
    assert card["enabled"] is False and card["runs_on"] == "Default → model @x:y"
    assert card["mac_seen_at"] is not None and card["memory_active"] is False
    assert set(card["totals"]) == {"memories", "bursts", "pending"}


def test_config_reflects_picks_and_skip(st, sent):
    _upload_chats(st)
    _post("/api/imessage-memory/settings", {"enabled": True,
                                            "skip": [{"handle": "mom@example.com", "label": "Mom"}]})
    _post("/api/imessage-memory/chat", {"guid": "one", "pick": False})
    _get("/api/imessage-memory/config")
    cfg = sent["body"]
    assert cfg == {"enabled": True, "chats": {"one": False, "grp": False},
                   "skip": ["mom@example.com"], "backfill": None}


def test_messages_post_records_device_and_ingests(st, sent):
    _upload_chats(st)
    _post("/api/imessage-memory/settings", {"enabled": True})
    _post("/api/imessage-memory/messages", {"device_id": "mac-9", "messages": [
        {"guid": "one", "rowid": 1, "ts": 100.0, "sender": "Sam Lee", "handle": "+15105550000",
         "is_from_me": False, "text": "hi"},
        {"guid": "grp", "rowid": 2, "ts": 100.0, "sender": "Sam Lee", "handle": "+15105550000",
         "is_from_me": False, "text": "hi all"}]})
    assert sent["body"] == {"ok": True, "accepted": 1, "duplicate": 0, "rejected": 1}
    assert st.settings()["mac_device_id"] == "mac-9"


def test_backfill_validation_and_conflict(st, sent):
    _post("/api/imessage-memory/backfill", {"from": 200, "to": 100})
    assert sent["status"] == 400
    _post("/api/imessage-memory/backfill", {"from": 100, "to": 200, "chats": ["one"]})
    job = sent["body"]["job"]
    assert job["status"] == "pending" and job["chats"] == ["one"] and st.pushed
    _post("/api/imessage-memory/backfill", {"from": 100, "to": 200})
    assert sent["status"] == 409
    _post("/api/imessage-memory/backfill/stop", {"id": job["id"]})
    assert st.job(job["id"])["status"] == "stopped"
    # Batches still in flight for a stopped job are dropped.
    _post("/api/imessage-memory/messages", {"job_id": job["id"], "messages": []})
    assert sent["body"]["stopped"] is True


def test_backfill_progress_done(st, sent):
    _post("/api/imessage-memory/backfill", {"from": 100, "to": 200})
    job_id = sent["body"]["job"]["id"]
    _post("/api/imessage-memory/backfill/progress", {"id": job_id, "done": True})
    assert st.job(job_id)["status"] == "done"


def test_forget_calls_memory_forget_prefix(st, sent, monkeypatch):
    calls = []

    class Mem:
        def forget(self, **kw):
            calls.append(kw)
            return 4

    monkeypatch.setattr(writer, "memory_writer", lambda: Mem())
    _post("/api/imessage-memory/forget", {"guid": "one"})
    assert sent["body"] == {"ok": True, "forgotten": 4}
    assert calls == [{"source_prefix": "imessage:one:"}]


def test_settings_change_pushes_frame_and_validates_agent(st, sent):
    _post("/api/imessage-memory/settings", {"agent": {"harness_id": "main"}})
    assert sent["body"]["agent"] == {"harness_id": "main"} and st.pushed
    _post("/api/imessage-memory/settings", {"agent": {"nope": 1}})
    assert sent["status"] == 400
    _post("/api/imessage-memory/settings", {"agent": None})
    assert sent["body"]["agent"] is None


def test_unknown_paths_fall_through(st, sent):
    assert _get("/api/imessage-memory/nope") is False
    assert _post("/api/imessage-memory/nope", {}) is False
