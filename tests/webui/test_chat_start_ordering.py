"""Ordering + persistence tests for /api/chat/start (plan task 1.2).

The worker thread is started BEFORE the pending session state is written to
disk, and that disk write uses ``skip_index=True`` so the SESSION_DIR glob in
``models._write_session_index`` never runs on the chat/start request path —
instead a debounced background refresh (``models.schedule_session_index_refresh``)
picks it up shortly after. These tests use a fake ``threading.Thread`` (never
actually running ``_run_agent_streaming``) and a fake ``Session`` to assert the
call order and flags without touching the filesystem.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.routes as routes  # noqa: E402


class _NullDiag:
    def stage(self, *_a, **_k):
        return None

    def finish(self):
        return None


class FakeThread:
    """Stand-in for threading.Thread that records start() without running
    the real target (``_run_agent_streaming`` needs a full agent stack)."""

    instances: list["FakeThread"] = []

    def __init__(self, target=None, args=(), kwargs=None, daemon=None):
        self.target = target
        self.args = args
        self.kwargs = kwargs or {}
        self.daemon = daemon
        self.started = False
        FakeThread.instances.append(self)

    def start(self):
        self.started = True
        events.append(("thread_start", None))


class FakeSession:
    def __init__(self, session_id="sess-1"):
        self.session_id = session_id
        self.workspace = None
        self.model = None
        self.model_provider = None
        self.active_stream_id = None
        self.pending_user_message = None
        self.pending_attachments = None
        self.pending_started_at = None
        self.title = "Untitled"
        self.save_calls: list[dict] = []

    def save(self, touch_updated_at: bool = True, skip_index: bool = False):
        self.save_calls.append({"skip_index": skip_index})
        events.append(("save", skip_index))


events: list[tuple] = []


def _patch_common(monkeypatch):
    events.clear()
    FakeThread.instances.clear()
    monkeypatch.setattr(routes.threading, "Thread", FakeThread)
    monkeypatch.setattr(routes, "get_webui_session_save_mode", lambda: "deferred")
    monkeypatch.setattr(routes, "set_last_workspace", lambda *_a, **_k: None)
    monkeypatch.setattr(routes, "create_stream_channel", lambda: object())

    import api.turn_journal as turn_journal

    monkeypatch.setattr(
        turn_journal, "append_turn_journal_event", lambda *_a, **_k: {"turn_id": "t1"}
    )

    refresh_calls = []
    import api.models as models

    monkeypatch.setattr(
        models,
        "schedule_session_index_refresh",
        lambda s: refresh_calls.append(s.session_id),
    )
    return refresh_calls


def test_thread_starts_before_disk_save(monkeypatch):
    """The worker thread is started before s.save() hits disk (plan 1.2)."""
    _patch_common(monkeypatch)
    s = FakeSession()

    response = routes._start_chat_stream_for_session(
        s,
        msg="hello",
        attachments=[],
        workspace="/tmp/ws",
        model="claude-haiku-4-5",
        diag=_NullDiag(),
    )

    assert FakeThread.instances and FakeThread.instances[0].started
    assert s.save_calls, "expected exactly one save() call"
    save_order = [i for i, (kind, _) in enumerate(events) if kind == "save"]
    thread_order = [i for i, (kind, _) in enumerate(events) if kind == "thread_start"]
    assert thread_order and save_order
    assert thread_order[0] < save_order[0], "thread must start before the disk save"


def test_disk_save_skips_index_and_schedules_refresh(monkeypatch):
    """save() uses skip_index=True and a debounced index refresh is scheduled."""
    refresh_calls = _patch_common(monkeypatch)
    s = FakeSession()

    routes._start_chat_stream_for_session(
        s,
        msg="hello",
        attachments=[],
        workspace="/tmp/ws",
        model="claude-haiku-4-5",
        diag=_NullDiag(),
    )

    assert len(s.save_calls) == 1
    assert s.save_calls[0]["skip_index"] is True
    assert refresh_calls == [s.session_id]


def test_pending_state_semantics_preserved(monkeypatch):
    """The response still carries stream_id/session_id/title as before, and the
    pending fields land on the session object exactly once (in-memory) before
    the disk write."""
    _patch_common(monkeypatch)
    s = FakeSession()

    response = routes._start_chat_stream_for_session(
        s,
        msg="hello there",
        attachments=[{"name": "a.png"}],
        workspace="/tmp/ws",
        model="claude-haiku-4-5",
        diag=_NullDiag(),
    )

    assert response["session_id"] == s.session_id
    assert "stream_id" in response and response["stream_id"]
    assert s.pending_user_message == "hello there"
    assert s.pending_attachments == [{"name": "a.png"}]
    assert s.workspace == "/tmp/ws"
    assert s.model == "claude-haiku-4-5"
