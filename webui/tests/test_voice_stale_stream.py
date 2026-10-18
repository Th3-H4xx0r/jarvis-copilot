"""begin_turn clears a stream the session left running, so the phone needn't ask.

A stream still running for the session (the app was backgrounded mid-turn) makes
the next voice turn fail with "session already has an active stream". The phone
used to clear it over HTTP before every begin_turn (GET /api/session, then
/api/chat/cancel) — a round trip that took seconds on a slow server. The voice
socket now does the same clearing in-process when begin_turn names the session,
and says so on its ``ready`` frame so the phone can skip the call.

The rule is the phone's: a turn that started recently is live, not orphaned (the
phone was backgrounded by an action the turn itself took, e.g. opening a URL), so
only a stream older than the grace is cancelled — and never this socket's own turn.
"""
from __future__ import annotations

import json
import queue
import sys
import threading
import time
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from api import config  # noqa: E402
from api import models  # noqa: E402
from api import voice  # noqa: E402
from api.models import Session  # noqa: E402

SID = "voice_stale_sid"
AN_HOUR = 3600.0


@pytest.fixture(autouse=True)
def _clean_streams():
    for registry in (config.STREAMS, config.CANCEL_FLAGS, config.AGENT_INSTANCES):
        registry.clear()
    voice._ACTIVE_VOICE_STREAMS.clear()
    yield
    for registry in (config.STREAMS, config.CANCEL_FLAGS, config.AGENT_INSTANCES):
        registry.clear()
    voice._ACTIVE_VOICE_STREAMS.clear()
    models.SESSIONS.pop(SID, None)


def _session(active_stream_id=None, started_ago=None):
    s = Session(session_id=SID, title="voice")
    s.active_stream_id = active_stream_id
    s.pending_user_message = "turn on the lights" if active_stream_id else None
    s.pending_started_at = (time.time() - started_ago) if started_ago is not None else None
    models.SESSIONS[SID] = s
    return s


def _running_stream(stream_id):
    """A stream registered the way chat start registers one."""
    config.STREAMS[stream_id] = queue.Queue()
    flag = threading.Event()
    config.CANCEL_FLAGS[stream_id] = flag
    return flag


def _state(**extra):
    return {
        "lock": threading.Lock(),
        "pcm_buf": bytearray(),
        "interrupt": False,
        "clarify_pending": False,
        "sample_rate": 16000,
        "session_id": "",
        **extra,
    }


class _DeadSocket:
    """begin_turn must not send anything: any use of the socket fails the test."""

    def send(self, *a, **k):  # pragma: no cover - must never be called
        raise AssertionError("begin_turn must not touch the socket")

    sendall = send


def _begin_turn(state, session_id=SID, asks=True):
    frame = {"type": "begin_turn", "sample_rate": 16000, "session_id": session_id}
    if asks:
        frame["clear_stale_stream"] = True  # the phone asks; the web and the Pod don't
    voice._handle_control_frame(frame, state, _DeadSocket(), _DeadSocket())


def test_a_client_that_does_not_ask_keeps_its_running_stream():
    # The web voice and the Pod open voice on a chat that may be running a long
    # agent turn: turning the mic on there must not cancel it.
    _session(active_stream_id="agent-run", started_ago=AN_HOUR)
    flag = _running_stream("agent-run")

    _begin_turn(_state(), asks=False)

    assert not flag.is_set()
    assert "agent-run" in config.STREAMS


def test_a_stream_older_than_the_grace_is_cancelled():
    _session(active_stream_id="orphan", started_ago=AN_HOUR)
    flag = _running_stream("orphan")

    _begin_turn(_state())

    # Cancelled exactly as /api/chat/cancel cancels: the worker is told to stop
    # and the session is released for the next turn.
    assert flag.is_set()
    assert "orphan" not in config.STREAMS


def test_a_stream_with_no_start_time_counts_as_orphaned():
    _session(active_stream_id="orphan", started_ago=None)
    flag = _running_stream("orphan")

    _begin_turn(_state())

    assert flag.is_set()
    assert "orphan" not in config.STREAMS


def test_a_turn_that_just_started_is_left_running():
    _session(active_stream_id="live", started_ago=5)
    flag = _running_stream("live")

    _begin_turn(_state())

    assert not flag.is_set()
    assert "live" in config.STREAMS


def test_no_active_stream_touches_nothing():
    _session(active_stream_id=None)
    other = _running_stream("another_sessions_turn")

    _begin_turn(_state())

    assert not other.is_set()
    assert "another_sessions_turn" in config.STREAMS


def test_an_unknown_session_is_not_an_error():
    other = _running_stream("another_sessions_turn")
    state = _state()

    _begin_turn(state, session_id="no_such_session")

    assert state["session_id"] == "no_such_session"
    assert not other.is_set()


def test_this_sockets_own_running_turn_is_never_cancelled():
    _session(active_stream_id="mine", started_ago=AN_HOUR)
    flag = _running_stream("mine")
    voice._ACTIVE_VOICE_STREAMS[SID] = "mine"
    release = threading.Event()
    turn = threading.Thread(target=release.wait, args=(5,), daemon=True)
    turn.start()
    try:
        _begin_turn(_state(session_id=SID, turn_thread=turn))
        assert not flag.is_set()
        assert "mine" in config.STREAMS
    finally:
        release.set()
        turn.join(2)


def test_another_sockets_orphaned_voice_turn_is_cancelled():
    """The phone reconnects on a new socket while the old one is still half-open
    with a turn running: that turn is not this socket's, so it is cleared."""
    _session(active_stream_id="old_socket_turn", started_ago=AN_HOUR)
    flag = _running_stream("old_socket_turn")
    voice._ACTIVE_VOICE_STREAMS[SID] = "old_socket_turn"

    _begin_turn(_state())

    assert flag.is_set()
    assert "old_socket_turn" not in config.STREAMS


def test_a_failure_while_clearing_never_escapes_begin_turn(monkeypatch):
    _running_stream("orphan")

    def _boom(*a, **k):
        raise RuntimeError("session store unavailable")

    monkeypatch.setattr(models, "get_session", _boom)
    state = _state()

    _begin_turn(state)  # must not raise into the socket loop

    assert state["session_id"] == SID


def _ensure_wsproto_events(monkeypatch):
    """The socket loop imports wsproto's event classes; the test venv may lack
    wsproto, and this test never receives a frame, so bare stand-ins do."""
    try:
        import wsproto.events  # noqa: F401
    except ImportError:
        events = types.ModuleType("wsproto.events")
        for name in ("TextMessage", "BytesMessage", "CloseConnection", "Ping", "Pong"):
            setattr(events, name, type(name, (), {}))
        monkeypatch.setitem(sys.modules, "wsproto", types.ModuleType("wsproto"))
        monkeypatch.setitem(sys.modules, "wsproto.events", events)


def test_the_ready_frame_says_the_server_clears_stale_streams(monkeypatch):
    _ensure_wsproto_events(monkeypatch)
    sent = []
    monkeypatch.setattr(voice, "_ws_send_text", lambda conn, sock, text: sent.append(text) or True)
    monkeypatch.setattr(voice, "_spawn_stt_warm", lambda: None)
    monkeypatch.setattr(voice, "_warm_ack_clips", lambda: None)

    class _ClosedSocket:
        def recv(self, n):
            return b""  # the client hangs up straight after the handshake

        def close(self):
            pass

    voice._run_voice_ws(object(), _ClosedSocket())

    ready = json.loads(sent[0])
    assert ready["type"] == "ready"
    assert ready["clears_stale_stream"] is True
