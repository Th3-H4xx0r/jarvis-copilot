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
    assert cfg.pop("enabled_at") > 0
    assert cfg == {"enabled": True, "chats": {"one": False, "grp": False},
                   "skip": ["mom@example.com"], "backfill": None}


def test_messages_post_records_device_and_ingests(st, sent, monkeypatch):
    monkeypatch.setattr(routes, "_request_device_id", lambda handler: "mac-9")
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
    st.update_settings(enabled=True)
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
    st.update_settings(enabled=True)
    _post("/api/imessage-memory/backfill", {"from": 100, "to": 200})
    job_id = sent["body"]["job"]["id"]
    _post("/api/imessage-memory/backfill/progress", {"id": job_id, "done": True})
    # Uploaded is not done: Jarvis still reads it, and the card says so.
    assert st.job(job_id)["status"] == "analyzing"
    assert st.active_job()["id"] == job_id
    st.finish_analyzed_jobs()                      # nothing waiting → done
    assert st.job(job_id)["status"] == "done" and st.active_job() is None


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


def test_config_get_records_device_id(st, sent, monkeypatch):
    monkeypatch.setattr(routes, "_request_device_id", lambda handler: "mac-7")
    routes.handle_get(None, urlparse("/api/imessage-memory/config"))
    assert st.settings()["mac_device_id"] == "mac-7"
    assert "enabled_at" in sent["body"]


def test_backfill_needs_it_on_and_switching_off_stops_it(st, sent):
    _post("/api/imessage-memory/settings", {"enabled": False})
    _post("/api/imessage-memory/backfill", {"from": 100, "to": 200})
    assert sent["status"] == 400
    _post("/api/imessage-memory/settings", {"enabled": True})
    _post("/api/imessage-memory/backfill", {"from": 100, "to": 200})
    job_id = sent["body"]["job"]["id"]
    _post("/api/imessage-memory/settings", {"enabled": False})
    assert st.job(job_id)["status"] == "stopped"


def test_mac_id_comes_from_its_session_and_nudges_never_guess(tmp_path, monkeypatch):
    """The bridge id is the paired device behind the Mac's session — never
    another connected device (the Pod and ESP32 boards hold bridges too)."""
    import api.device_bridge as bridge
    s = im.IMStore(tmp_path / "im.db")
    sent_to = []
    monkeypatch.setattr(bridge, "send_frame", lambda d, f: sent_to.append(d) or True)
    monkeypatch.setattr(bridge, "connected_device_ids", lambda: ["pod-id", "mac-bridge-id"])
    assert routes.push_refresh(s) is False and sent_to == []          # nothing known: no guess
    monkeypatch.setattr(routes, "_request_device_id", lambda handler: "mac-bridge-id")
    routes._seen(s, object())
    assert s.settings()["mac_device_id"] == "mac-bridge-id"
    assert routes.push_refresh(s) is True and sent_to == ["mac-bridge-id"]
    assert routes._mac_connected(s) is True


def test_settings_toggles_and_card_fields(st, sent):
    _post("/api/imessage-memory/settings", {"ask_facts": False, "push_facts": False})
    card = sent["body"]
    assert card["ask_facts"] is False and card["push_facts"] is False
    assert card["pending_facts"] == 0 and "mac_connected" in card


def test_facts_list_and_decide(st, sent, monkeypatch):
    st.update_settings(enabled=True)
    _upload_chats(st)
    st.ingest([{"guid": "one", "rowid": 1, "ts": 100.0, "sender": "Sam Lee", "handle": "+15105550000",
                "is_from_me": False, "text": "hi"}])
    (burst,) = st.open_bursts(100.0 + 1800)
    st.add_fact_cards(burst, "Sam Lee", [("Fact one is here", "Fact one is here (s)")], "imessage:one:fact:1-1:f")
    routes.handle_get(None, urlparse("/api/imessage-memory/facts"))
    (card,) = sent["body"]["facts"]
    _post("/api/imessage-memory/facts/decide", {"ids": [card["id"]]})
    assert sent["status"] == 400                                  # store missing
    _post("/api/imessage-memory/facts/decide", {"burst": "one|1", "store": False})
    assert sent["body"] == {"ok": True, "decided": 1}


def test_preview_roundtrip(st, sent, monkeypatch):
    import threading as _t

    def fake_send(store, frame):
        assert frame["op"] == "preview" and frame["guid"] == "one"
        _t.Timer(0.05, lambda: routes.deliver_preview(frame["request_id"], {
            "messages": [{"ts": 1.0, "sender": "Sam Lee", "is_from_me": False, "text": "hi"}]})).start()
        return True

    monkeypatch.setattr(routes, "_send_to_mac", fake_send)
    routes.handle_get(None, urlparse("/api/imessage-memory/preview?guid=one"))
    assert sent["body"]["messages"][0]["text"] == "hi"


def test_preview_times_out(st, sent, monkeypatch):
    monkeypatch.setattr(routes, "_send_to_mac", lambda store, frame: True)
    monkeypatch.setattr(routes, "PREVIEW_TIMEOUT", 0.1)
    routes.handle_get(None, urlparse("/api/imessage-memory/preview?guid=one"))
    assert sent["status"] == 504 and "awake" in sent["body"]["error"]
    monkeypatch.setattr(routes, "_send_to_mac", lambda store, frame: False)
    routes.handle_get(None, urlparse("/api/imessage-memory/preview?guid=one"))
    assert sent["status"] == 504 and "isn't connected" in sent["body"]["error"]


class _ChatMemory:
    def __init__(self):
        self.deleted = []

    def memories(self, prefix, limit=200):
        assert prefix == "imessage:one:"
        return [{"id": "f1", "body": "Sam's address is 12 Oak St (from an iMessage chat with Sam Lee on Tue 19 Oct 2026 18:02 PDT)",
                 "source": "imessage:one:fact:1-2:f", "created_at": 200.0},
                {"id": "c1", "body": "iMessage with Sam Lee — Tue\nParticipants: Me, Sam Lee\n[18:02] Sam Lee: hi",
                 "source": "imessage:one:1-2:p1", "created_at": 100.0}]

    def delete(self, chunk_id, source_prefix):
        self.deleted.append((chunk_id, source_prefix))
        return True


def test_chat_memories_split_facts_conversations_waiting(st, sent, monkeypatch):
    mem = _ChatMemory()
    monkeypatch.setattr(writer, "memory_writer", lambda: mem)
    routes.handle_get(None, urlparse("/api/imessage-memory/memories?guid=one"))
    body = sent["body"]
    assert body["facts"] == [{"id": "f1", "text": "Sam's address is 12 Oak St", "at": 200.0}]
    assert [c["id"] for c in body["conversations"]] == ["c1"] and body["waiting"] == []


def test_memory_delete_is_limited_to_imessage(st, sent, monkeypatch):
    mem = _ChatMemory()
    monkeypatch.setattr(writer, "memory_writer", lambda: mem)
    _post("/api/imessage-memory/memories/delete", {"id": "f1"})
    assert sent["body"] == {"ok": True, "deleted": True}
    assert mem.deleted == [("f1", "imessage:")]
