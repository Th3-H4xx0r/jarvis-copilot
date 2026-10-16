"""The hand-off jobs feed and speak-back.

A Background job (a fast node handing a turn to the bigger model) shows in the
Mac island's Agents tab: the server pushes every recent job on the device
bridge's ``harness_jobs`` topic — what was asked, where from, its steps and its
answer. A job started from a VOICE turn whose conversation has since closed
(push to talk on the Mac) is read out by the device that asked: the finished
job goes to that device alone, with ``speak``."""
import json
import queue
from types import SimpleNamespace

import pytest

import api.config  # noqa: F401  (puts the agent checkout on sys.path)
import api.harness_runner as hr
from agent import escalation
from api import device_bridge as db
from api import turn_origin


@pytest.fixture(autouse=True)
def _clean():
    escalation.reset_for_tests()
    yield
    escalation.reset_for_tests()
    turn_origin.note_turn("s1", None)


class _FakeSock:
    def shutdown(self, *_a):
        pass

    def close(self):
        pass


@pytest.fixture
def frames(monkeypatch):
    sent = []
    monkeypatch.setattr(db, "_ws_send_text", lambda conn, text: sent.append((conn.device_id, json.loads(text))))
    return sent


@pytest.fixture
def device():
    made = []

    def make(device_id, topics):
        conn = db._DeviceConn(device_id=device_id, sock=_FakeSock(), conn=None, name="mac")
        db._register(conn)
        made.append(conn)
        db._handle_message(conn, {"type": "subscribe", "topics": topics})
        return conn

    yield make
    for conn in made:
        db._safe_close(conn)
        db._unregister(conn.device_id, conn)


def _job(job_id="j1", session_id="s1", origin=None, **extra):
    job = {"job_id": job_id, "session_id": session_id, "reason": "harness:claude",
           "summary": "Compare against dealer offers", "model": "@claude-code:claude-sonnet-5-5",
           "status": "running", "started_at": 100.0, "completed_at": None, "text": None,
           "parent": {"node_id": "claude", "node_label": "claude", "kind": "background",
                      "question": "compare these against dealer and lease offers"},
           "origin": dict(origin or {})}
    job.update(extra)
    with escalation._lock:
        escalation._jobs[job_id] = job
    return job


class FakeSession(SimpleNamespace):
    def save(self, **kw):
        pass


def _topic(sent, device_id=None):
    return [f for d, f in sent if f.get("type") == "topic" and f.get("topic") == hr.JOBS_TOPIC
            and (device_id is None or d == device_id)]


VOICE_MAC = {"surface": "voice", "device_id": "mac-1", "name": "Pranav's MacBook", "kind": "browser", "mac": True}


# ── the feed ─────────────────────────────────────────────────────────────────

def test_a_feed_entry_says_what_was_asked_where_from_and_what_came_back():
    job = _job(origin=VOICE_MAC, steps=2, activity="Searching the web",
               trail=[{"t": "Searching the web", "tool": "web_search", "detail": "lease offers", "at": 1.0}],
               result="The dealer's offer is $2k under.")
    entry = hr.job_feed_entry(job)
    assert entry["id"] == "j1" and entry["status"] == "running" and entry["steps"] == 2
    assert entry["task"] == "compare these against dealer and lease offers"
    assert entry["note"] == "Compare against dealer offers"
    assert entry["surface"] == "voice" and entry["device"] == "Pranav's MacBook" and entry["mac"] is True
    assert entry["trail"][0]["detail"] == "lease offers"
    assert entry["result"] == "The dealer's offer is $2k under."


def test_the_feed_is_recent_background_jobs_newest_first():
    _job("old-done", started_at=10.0, status="done", completed_at=20.0)
    _job("a", started_at=100.0)
    _job("b", started_at=200.0, status="done", completed_at=250.0)
    _job("review", started_at=300.0, parent={"node_id": "r", "kind": "review"})
    feed = hr.jobs_feed(now=20.0 + escalation.JOB_RETENTION_SECONDS + 1)
    assert [e["id"] for e in feed] == ["b", "a"]


def test_the_feed_is_capped():
    for i in range(hr.FEED_MAX + 3):
        _job(f"j{i}", started_at=float(i))
    assert len(hr.jobs_feed()) == hr.FEED_MAX


def test_progress_keeps_the_recent_steps_with_what_each_was_on(monkeypatch):
    monkeypatch.setattr(hr, "_publish_job", lambda sid, card: None)
    _job()
    q = queue.Queue()
    for item in [("tool", {"name": "web_search", "event_type": "tool.started", "preview": "lease  offers\n2026"}),
                 ("tool", {"name": "web_search", "event_type": "tool.completed"}),
                 ("tool", {"name": "web_extract", "preview": "https://dealer.example"}),
                 ("stream_end", {})]:
        q.put(item)
    hr._watch_progress(q, "s1", "j1")
    trail = escalation.get_job("j1")["trail"]
    assert [(s["t"], s["detail"]) for s in trail] == [("Searching the web", "lease offers 2026"),
                                                      ("Reading web pages", "https://dealer.example")]


def test_a_changed_job_goes_out_on_the_topic(frames, device):
    device("mac-1", {hr.JOBS_TOPIC: 0})
    device("phone", {"pods": 0})
    _job()
    hr._publish_job("s1", hr.job_card(escalation.get_job("j1")))
    got = _topic(frames)
    assert [d for d, f in frames if f.get("topic") == hr.JOBS_TOPIC] == ["mac-1"]
    assert got[-1]["data"]["jobs"][0]["id"] == "j1" and "speak" not in got[-1]["data"]


def test_subscribing_while_a_job_runs_catches_the_device_up(frames, device):
    _job()
    device("mac-1", {hr.JOBS_TOPIC: 0})
    hr._on_subscribe("mac-1", {hr.JOBS_TOPIC: 0})
    assert _topic(frames, "mac-1")[-1]["data"]["jobs"][0]["id"] == "j1"


def test_publish_to_reaches_only_that_device_and_only_when_subscribed(frames, device):
    device("mac-1", {hr.JOBS_TOPIC: 30})
    device("mac-2", {hr.JOBS_TOPIC: 0})
    device("phone", {"pods": 0})
    assert db.publish_to("mac-1", hr.JOBS_TOPIC, {"x": 1}) is True
    assert db.publish_to("phone", hr.JOBS_TOPIC, {"x": 1}) is False
    assert db.publish_to("nobody", hr.JOBS_TOPIC, {"x": 1}) is False
    assert [d for d, f in frames if f.get("type") == "topic"] == ["mac-1"]


# ── where a job comes from ───────────────────────────────────────────────────

def test_a_job_knows_the_turn_it_came_from():
    turn_origin.note_turn("s1", {"device_id": "mac-1", "name": "MacBook", "kind": "desktop"})
    origin = hr.job_origin("s1", "voice")
    assert origin == {"surface": "voice", "device_id": "mac-1", "name": "MacBook", "kind": "desktop",
                      "mac": True}
    assert hr.job_origin("unknown", None) == {"surface": "chat"}


def test_a_hand_off_takes_its_origin_from_the_turn_context():
    job_id = escalation.start_escalation(session_id="s1", reason="r", summary="s",
                                         runner=lambda job: "", parent={"origin": VOICE_MAC})
    assert escalation.get_job(job_id)["origin"]["surface"] == "voice"


def test_after_jobs_carry_the_turns_origin(monkeypatch):
    seen = []
    monkeypatch.setattr(hr, "_start_job", lambda sid, node, runner, origin=None: seen.append(origin) or "j")
    plan = SimpleNamespace(surface="voice", after=[({"id": "bg", "type": "background", "model": "m"}, "always")])
    hr.start_after_jobs(plan, session_id="s1", question="q", answer="a", elapsed_s=1, tool_count=0)
    assert seen == [{"surface": "voice"}]


def test_only_a_voice_socket_counts_as_speaking():
    escalation.register_stream_sink("s1", lambda event, data: None)       # a chat stream
    assert escalation.has_live_sink("s1") and not escalation.has_speaking_sink("s1")

    def voice(event, data):
        pass

    voice.speaks = True
    escalation.register_stream_sink("s1", voice)
    assert escalation.has_speaking_sink("s1")


# ── speak-back ───────────────────────────────────────────────────────────────

def _finish(monkeypatch, origin, answer="The lease is cheaper by $40 a month."):
    """Run a job to its end the way the registry does; what the socket gets,
    what the chat gets."""
    delivered, posted = [], []
    monkeypatch.setattr(hr, "_load_session", lambda sid: FakeSession(session_id=sid, messages=[]))
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(kw) or {})
    monkeypatch.setattr(hr, "_run_hidden_turn", lambda node, sid, summary, job_id=None: answer)
    _job(origin=origin)
    node = {"id": "claude", "model": "m", "deliver": "speak_or_notify"}
    escalation._run_job("j1", hr.background_runner(node, "s1"))
    escalation.register_stream_sink("s1", lambda event, data: delivered.append(data))  # the next socket
    return delivered, posted


def test_a_voice_job_whose_conversation_closed_is_read_out_by_the_device_that_asked(monkeypatch, frames, device):
    device("mac-1", {hr.JOBS_TOPIC: 0})
    device("mac-2", {hr.JOBS_TOPIC: 0})
    delivered, posted = _finish(monkeypatch, VOICE_MAC)
    speak = [f["data"]["speak"] for f in _topic(frames) if "speak" in f["data"]]
    assert [d for d, f in frames if "speak" in (f.get("data") or {})] == ["mac-1"]
    assert speak[0]["result"] == "The lease is cheaper by $40 a month." and speak[0]["status"] == "done"
    # Said once: not again by the next voice socket, and no push to the phone.
    assert delivered == [] and posted[0]["spoken"] is True


def test_an_open_voice_socket_speaks_it_itself(monkeypatch, frames, device):
    device("mac-1", {hr.JOBS_TOPIC: 0})

    def voice(event, data):
        pass

    voice.speaks = True
    escalation.register_stream_sink("s1", voice)
    _, posted = _finish(monkeypatch, VOICE_MAC)
    assert not [f for f in _topic(frames) if "speak" in f["data"]] and posted[0]["spoken"] is False


def test_a_chat_job_is_not_read_out(monkeypatch, frames, device):
    device("mac-1", {hr.JOBS_TOPIC: 0})
    _finish(monkeypatch, dict(VOICE_MAC, surface="chat"))
    assert not [f for f in _topic(frames) if "speak" in f["data"]]


def test_a_device_that_does_not_listen_keeps_the_old_way(monkeypatch, frames, device):
    """The phone's voice, say: the answer waits for its next voice socket."""
    device("phone-1", {"pods": 0})
    delivered, posted = _finish(monkeypatch, dict(VOICE_MAC, device_id="phone-1"))
    assert [d["text"] for d in delivered] == ["The lease is cheaper by $40 a month."]
    assert posted[0]["spoken"] is False


def test_a_failed_voice_job_says_so_out_loud(monkeypatch, frames, device):
    device("mac-1", {hr.JOBS_TOPIC: 0})
    monkeypatch.setattr(hr, "_load_session", lambda sid: FakeSession(session_id=sid, messages=[]))
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: {})

    def boom(*a, **kw):
        raise RuntimeError("quota")

    monkeypatch.setattr(hr, "_run_hidden_turn", boom)
    _job(origin=VOICE_MAC)
    escalation._run_job("j1", hr.background_runner({"id": "claude", "model": "m", "deliver": "speak_or_notify"}, "s1"))
    speak = [f["data"]["speak"] for f in _topic(frames) if "speak" in f["data"]][0]
    assert speak["status"] == "failed" and "Couldn't finish" in speak["result"] and speak["error"] == "quota"
