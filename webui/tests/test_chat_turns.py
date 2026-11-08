"""Starting a chat turn (api/chat_turns.start_turn): what a reload, the journal and the worker see."""
import pytest

import api.chat_turns as chat_turns
from api import config
from api.models import Session
from api.turn_options import TurnOptions


@pytest.fixture
def started(monkeypatch):
    """start_turn with the worker thread and journal recorded instead of run."""
    events = []
    monkeypatch.setattr(Session, "save", lambda self, *a, **k: None)
    monkeypatch.setattr(chat_turns, "set_last_workspace", lambda workspace: None)

    class RecordedThread:
        def __init__(self, target=None, args=(), kwargs=None, **_):
            self.kwargs = kwargs or {}
            events.append(("thread", self))

        def start(self):
            events.append(("start", self.kwargs))

    monkeypatch.setattr(chat_turns.threading, "Thread", RecordedThread)

    import api.turn_journal as turn_journal

    def journal(session_id, event):
        events.append(("journal", event))
        return {"turn_id": "t1"}
    monkeypatch.setattr(turn_journal, "append_turn_journal_event", journal)

    stream_ids = []

    def start(session, **kw):
        kw.setdefault("attachments", [])
        kw.setdefault("workspace", "/tmp")
        kw.setdefault("model", "m")
        response = chat_turns.start_turn(session, **kw)
        stream_ids.append(response.get("stream_id"))
        return response

    yield start, events
    with config.STREAMS_LOCK:
        for sid in stream_ids:
            config.STREAMS.pop(sid, None)
            config.STREAM_GOAL_RELATED.pop(sid, None)


def test_a_reload_finds_the_pending_turn_on_the_session(started):
    start, _ = started
    s = Session(session_id="turn-reload", title="Untitled")
    response = start(s, msg="hello there", attachments=["a.png"])
    assert s.active_stream_id == response["stream_id"]
    assert s.pending_user_message == "hello there"
    assert s.pending_attachments == ["a.png"]
    assert response["turn_id"] == "t1"


def test_the_turn_is_journaled_as_submitted_before_the_worker_starts(started):
    start, events = started
    start(Session(session_id="turn-journal"), msg="hi")
    kinds = [k for k, _ in events]
    assert kinds.index("journal") < kinds.index("start")
    journal = next(e for k, e in events if k == "journal")
    assert journal["event"] == "submitted" and journal["role"] == "user" and journal["content"] == "hi"


def test_a_journal_failure_does_not_stop_the_turn(started, monkeypatch):
    start, events = started
    import api.turn_journal as turn_journal

    def broken(*_):
        raise OSError("disk full")
    monkeypatch.setattr(turn_journal, "append_turn_journal_event", broken)
    response = start(Session(session_id="turn-journal-broken"), msg="hi")
    assert response["stream_id"] and ("start" in [k for k, _ in events])


def test_the_turn_options_reach_the_worker(started):
    start, events = started
    turn = TurnOptions(surface="voice", reasoning_off=True)
    start(Session(session_id="turn-options"), msg="hi", turn=turn)
    assert next(kw for k, kw in events if k == "start")["turn"] is turn


def test_a_turn_without_options_gets_the_defaults(started):
    start, events = started
    start(Session(session_id="turn-defaults"), msg="hi")
    assert next(kw for k, kw in events if k == "start")["turn"] == TurnOptions()


def test_a_pending_goal_continuation_is_consumed_once(started):
    start, events = started
    s = Session(session_id="turn-goal")
    config.PENDING_GOAL_CONTINUATION.add(s.session_id)
    first = start(s, msg="continue")
    assert config.STREAM_GOAL_RELATED.get(first["stream_id"]) is True
    assert s.session_id not in config.PENDING_GOAL_CONTINUATION
    assert next(kw for k, kw in events if k == "start")["goal_related"] is True


def test_a_second_turn_while_one_runs_is_refused(started):
    start, _ = started
    s = Session(session_id="turn-busy")
    first = start(s, msg="one")
    with config.STREAMS_LOCK:
        config.STREAMS[first["stream_id"]] = config.create_stream_channel()
    second = chat_turns.start_turn(s, msg="two", attachments=[], workspace="/tmp", model="m")
    assert second["_status"] == 409 and second["active_stream_id"] == first["stream_id"]


def test_a_stale_stream_from_a_dead_run_is_cleared_and_the_turn_starts(started):
    start, _ = started
    s = Session(session_id="turn-stale")
    s.active_stream_id = "gone-after-restart"
    s.pending_user_message = "an old prompt"
    response = start(s, msg="new prompt")
    assert response["stream_id"] != "gone-after-restart"
    assert s.active_stream_id == response["stream_id"] and s.pending_user_message == "new prompt"
