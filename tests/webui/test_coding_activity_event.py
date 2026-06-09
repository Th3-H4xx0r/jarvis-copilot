"""The instant, hook-driven activity_state endpoint (``POST /activity-event``).

A Claude Code Stop/Notification/UserPromptSubmit hook (via ``jc-client
coding-event``) reports the live transition the moment it happens, so the iOS
Live Activity and WebUI update instantly instead of waiting for the 4-5s poll
loops. These tests pin the event→state mapping, the session-matching priority,
and the change-only write."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.coding_routes as cr  # noqa: E402
from api.coding_routes import handle_coding_request  # noqa: E402


class FakeStore:
    def __init__(self, rows):
        self.rows = rows
        self.updates = []

    def list_sessions(self, **kw):
        return [dict(r) for r in self.rows]

    def update_session(self, sid, **fields):
        self.updates.append((sid, fields))
        for r in self.rows:
            if r["id"] == sid:
                r.update(fields)

    # Touched by the (real) push_coding_update fan-out; harmless no-ops here.
    def list_projects(self):
        return []

    def list_la_tokens(self):
        return []


class FakeManager:
    def __init__(self, store):
        self.store = store


def _row(sid, **kw):
    base = {"id": sid, "tmux_name": None, "claude_session_id": None,
            "cwd": None, "status": "running", "host": "server",
            "activity_state": None, "project_id": None, "source": "chat"}
    base.update(kw)
    return base


def _post(rows, body):
    mgr = FakeManager(FakeStore(rows))
    status, payload = handle_coding_request(
        "POST", "/activity-event", body, manager=mgr)
    return status, payload, mgr.store


def test_stop_event_sets_idle():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1", activity_state="working")],
        {"event": "stop", "tmux_name": "jc-1"})
    assert status == 200
    assert payload["matched"] is True and payload["changed"] is True
    assert payload["state"] == "idle"
    assert store.updates == [("cs_1", {"activity_state": "idle"})]


def test_notification_event_sets_waiting():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1", activity_state="working")],
        {"event": "notification", "tmux_name": "jc-1"})
    assert payload["state"] == "waiting"
    assert store.updates == [("cs_1", {"activity_state": "waiting"})]


def test_user_prompt_submit_sets_working():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1", activity_state="idle")],
        {"event": "user_prompt_submit", "tmux_name": "jc-1"})
    assert payload["state"] == "working"
    assert store.updates == [("cs_1", {"activity_state": "working"})]


def test_unknown_event_is_400():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1")], {"event": "wat", "tmux_name": "jc-1"})
    assert status == 400
    assert store.updates == []


def test_no_match_reports_unmatched_without_writing():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1")],
        {"event": "stop", "tmux_name": "nope"})
    assert status == 200
    assert payload["matched"] is False
    assert store.updates == []


def test_no_write_when_state_unchanged():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1", activity_state="idle")],
        {"event": "stop", "tmux_name": "jc-1"})
    assert payload["matched"] is True and payload["changed"] is False
    assert store.updates == []  # already idle → no redundant write/push


def test_match_by_claude_session_id_when_no_tmux():
    status, payload, store = _post(
        [_row("cs_1", claude_session_id="abc-123")],
        {"event": "notification", "claude_session_id": "abc-123"})
    assert payload["matched"] is True
    assert store.updates == [("cs_1", {"activity_state": "waiting"})]


def test_match_by_cwd_only_when_unique():
    # Two live rows share the cwd → ambiguous → no match (don't guess wrong).
    status, payload, store = _post(
        [_row("cs_1", cwd="/repo"), _row("cs_2", cwd="/repo")],
        {"event": "stop", "cwd": "/repo"})
    assert payload["matched"] is False
    assert store.updates == []


def test_tmux_takes_priority_over_cwd():
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1", cwd="/repo"),
         _row("cs_2", tmux_name="jc-2", cwd="/repo")],
        {"event": "stop", "tmux_name": "jc-2", "cwd": "/repo"})
    assert store.updates == [("cs_2", {"activity_state": "idle"})]


def test_skips_non_live_session():
    # A stopped row with a matching tmux name must NOT be revived/classified.
    status, payload, store = _post(
        [_row("cs_1", tmux_name="jc-1", status="stopped")],
        {"event": "stop", "tmux_name": "jc-1"})
    assert payload["matched"] is False
    assert store.updates == []


# ── Visible phone-banner fan-out (reaches a force-quit phone) ─────────────────

def _post_capturing_alerts(monkeypatch, rows, body):
    calls = []
    monkeypatch.setattr(cr, "_push_device_alert",
                        lambda title, b: calls.append((title, b)) or 1)
    mgr = FakeManager(FakeStore(rows))
    handle_coding_request("POST", "/activity-event", body, manager=mgr)
    return calls


def test_stop_sends_finished_banner(monkeypatch):
    calls = _post_capturing_alerts(
        monkeypatch,
        [_row("cs_1", tmux_name="jc-1", cwd="/home/me/acme", activity_state="working")],
        {"event": "stop", "tmux_name": "jc-1"})
    assert calls == [("✅ Claude finished", "acme")]


def test_notification_sends_needs_you_banner(monkeypatch):
    calls = _post_capturing_alerts(
        monkeypatch,
        [_row("cs_1", tmux_name="jc-1", cwd="/home/me/acme")],
        {"event": "notification", "tmux_name": "jc-1"})
    assert calls == [("🔔 Claude needs you", "acme")]


def test_user_prompt_submit_sends_no_banner(monkeypatch):
    calls = _post_capturing_alerts(
        monkeypatch,
        [_row("cs_1", tmux_name="jc-1", activity_state="idle")],
        {"event": "user_prompt_submit", "tmux_name": "jc-1"})
    assert calls == []  # a working-edge must never banner the phone


def test_unmatched_event_still_banners_with_cwd_label(monkeypatch):
    # DELIBERATE: the finished/needs-input banner fires even when no row could
    # be matched (e.g. the hook beat the 5s discovery scan), labeled by the
    # event's OWN cwd — never by a guessed row. What an unmatched event must
    # NOT do is write activity_state anywhere (no store updates).
    calls = []
    monkeypatch.setattr(cr, "_push_device_alert",
                        lambda title, b: calls.append((title, b)) or 1)
    mgr = FakeManager(FakeStore([_row("cs_1", tmux_name="jc-1")]))
    handle_coding_request(
        "POST", "/activity-event",
        {"event": "stop", "tmux_name": "nope", "cwd": "/x/elsewhere"},
        manager=mgr)
    assert calls == [("✅ Claude finished", "elsewhere")]
    assert mgr.store.updates == []


def test_stop_banner_fires_even_when_state_unchanged(monkeypatch):
    # A finish is a finish — the user should be told even if the stored state
    # was already idle (mirrors the Telegram hook firing on every Stop).
    calls = _post_capturing_alerts(
        monkeypatch,
        [_row("cs_1", tmux_name="jc-1", cwd="/x/proj", activity_state="idle")],
        {"event": "stop", "tmux_name": "jc-1"})
    assert calls == [("✅ Claude finished", "proj")]


def test_alert_label_prefers_project_name(monkeypatch):
    class StoreWithProject(FakeStore):
        def get_project(self, pid):
            return {"id": pid, "name": "Acme API"} if pid == "p1" else None

    calls = []
    monkeypatch.setattr(cr, "_push_device_alert",
                        lambda title, b: calls.append((title, b)) or 1)
    mgr = FakeManager(StoreWithProject(
        [_row("cs_1", tmux_name="jc-1", cwd="/x/folder", project_id="p1")]))
    handle_coding_request("POST", "/activity-event",
                          {"event": "stop", "tmux_name": "jc-1"}, manager=mgr)
    assert calls == [("✅ Claude finished", "Acme API")]
