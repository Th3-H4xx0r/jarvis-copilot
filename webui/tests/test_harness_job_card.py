"""The background-job card: a running harness Background job shows in the chat
as a card (label, live step, elapsed time, Stop) under the reply that started
it, collapses to one line when it ends, and survives a reload.

Server side: the card lives in the starting reply's ``_meta.jobs``; live
changes go out as ``harness_job`` session events; ``/api/harnesses/jobs/...``
serves catch-up and Stop."""
import queue
from types import SimpleNamespace

import pytest

import api.config  # noqa: F401  (puts the agent checkout on sys.path)
import api.harness_runner as hr
from agent import escalation


@pytest.fixture(autouse=True)
def _clean_registry():
    escalation.reset_for_tests()
    yield
    escalation.reset_for_tests()


class FakeSession(SimpleNamespace):
    saves = 0

    def save(self, **kw):
        self.saves += 1


def _events(monkeypatch):
    sent = []
    monkeypatch.setattr(hr, "_publish_job", lambda sid, card: sent.append((sid, dict(card))))
    return sent


def _job(job_id="j1", session_id="s1", **extra):
    """A registry entry the way start_escalation makes it."""
    job = {"job_id": job_id, "session_id": session_id, "reason": "harness:bg", "summary": "",
           "model": "@anthropic-api:claude-sonnet-5-5", "status": "running", "started_at": 100.0,
           "completed_at": None, "text": None,
           "parent": {"node_id": "bg", "node_label": "Long Running", "kind": "background"}}
    job.update(extra)
    with escalation._lock:
        escalation._jobs[job_id] = job
    return job


# ── activity text ────────────────────────────────────────────────────────────

def test_tool_activity_reads_as_what_it_is_doing():
    assert hr.tool_activity("web_search") == "Searching the web"
    assert hr.tool_activity("browser_navigate") == "Using the browser"
    assert hr.tool_activity("chrome_click") == "Using the browser"
    assert hr.tool_activity("toyota_status") == "Using toyota status"
    assert hr.tool_activity("") == "Working"


# ── the card ─────────────────────────────────────────────────────────────────

def test_job_card_from_a_registry_entry():
    card = hr.job_card(_job(steps=6, activity="Searching the web"))
    assert card == {"id": "j1", "node": "bg", "label": "Long Running",
                    "model": "@anthropic-api:claude-sonnet-5-5", "status": "running",
                    "started_at": 100.0, "completed_at": None, "steps": 6,
                    "activity": "Searching the web", "stopping": False}


def test_job_card_without_node_info_still_reads():
    card = hr.job_card({"job_id": "j2", "status": "done", "started_at": 1.0})
    assert card["label"] == "Background" and card["steps"] == 0 and card["status"] == "done"


def test_turn_job_cards_are_this_turns_background_jobs_only():
    _job("old", started_at=50.0)
    _job("new", started_at=150.0)
    _job("review", started_at=160.0, parent={"node_id": "r", "kind": "review"})
    _job("other", session_id="s2", started_at=170.0)
    assert [c["id"] for c in hr.turn_job_cards("s1", since=100.0)] == ["new"]


def test_session_job_cards_list_background_jobs_of_that_chat():
    _job("a")
    _job("b", session_id="s2")
    _job("c", parent={"node_id": "r", "kind": "review"})
    assert [c["id"] for c in hr.session_job_cards("s1")] == ["a"]


def test_catch_up_answers_for_every_card_in_the_chat(monkeypatch):
    """The live jobs, plus the cards stored on the chat's replies: ended ones as
    stored, a stored running one the server no longer has as lost."""
    _job("j1", steps=4)
    stored = [dict(hr.job_card(escalation.get_job("j1")), steps=1),
              {"id": "j2", "label": "Long Running", "status": "running", "started_at": 90.0},
              {"id": "j3", "label": "Long Running", "status": "done", "started_at": 80.0, "completed_at": 85.0}]
    sess = FakeSession(session_id="s1", messages=[
        {"role": "assistant", "content": "On it.", "_meta": {"jobs": stored}}])
    monkeypatch.setattr(hr, "_load_session", lambda sid: sess)
    cards = {c["id"]: c for c in hr.session_job_cards("s1")}
    assert cards["j1"]["steps"] == 4                       # the live one wins
    assert cards["j2"]["status"] == "lost"
    assert cards["j3"]["status"] == "done"


def test_catch_up_survives_an_unknown_chat(monkeypatch):
    def gone(sid):
        raise KeyError(sid)

    monkeypatch.setattr(hr, "_load_session", gone)
    _job("j1")
    assert [c["id"] for c in hr.session_job_cards("s1")] == ["j1"]


def test_attach_job_cards_puts_them_on_the_reply_once(monkeypatch):
    sent = _events(monkeypatch)
    reply = {"role": "assistant", "content": "On it.", "_meta": {"kind": "answer", "model": "m"}}
    sess = FakeSession(session_id="s1", messages=[reply])
    card = hr.job_card(_job())
    hr.attach_job_cards(sess, reply, [card])
    hr.attach_job_cards(sess, reply, [card])
    assert [j["id"] for j in reply["_meta"]["jobs"]] == ["j1"]
    assert sess.saves == 2 and [c["id"] for _, c in sent] == ["j1", "j1"]


# ── registry ─────────────────────────────────────────────────────────────────

def test_update_job_merges_fields():
    _job()
    assert escalation.update_job("j1", steps=3, activity="Reading files")["steps"] == 3
    assert escalation.get_job("j1")["activity"] == "Reading files"
    assert escalation.update_job("nope", steps=1) is None


def test_run_job_keeps_a_status_the_runner_set():
    delivered = []
    escalation.register_stream_sink("s1", lambda event, data: delivered.append(data))

    def runner(job):
        escalation.update_job(job["job_id"], status="stopped")
        return ""

    _job()
    escalation._run_job("j1", runner)
    assert escalation.get_job("j1")["status"] == "stopped" and delivered == []


# ── progress ─────────────────────────────────────────────────────────────────

def test_progress_counts_steps_and_publishes_only_changes(monkeypatch):
    sent = _events(monkeypatch)
    _job()
    q = queue.Queue()
    for item in [("tool", {"name": "web_search", "event_type": "tool.started"}),
                 ("tool", {"name": "web_search", "event_type": "tool.completed"}),
                 ("reasoning", {"text": "hmm"}),
                 ("tool", {"name": "web_extract"}),
                 ("token", {"text": "Here"}), ("token", {"text": " is"}),
                 ("stream_end", {})]:
        q.put(item)
    hr._watch_progress(q, "s1", "j1")
    job = escalation.get_job("j1")
    assert job["steps"] == 2 and job["activity"] == "Writing the reply"
    assert [(c["steps"], c["activity"]) for _, c in sent] == [
        (1, "Searching the web"), (2, "Reading web pages"), (2, "Writing the reply")]


# ── finishing ────────────────────────────────────────────────────────────────

def _started_reply(monkeypatch):
    reply = {"role": "assistant", "content": "On it.",
             "_meta": {"kind": "answer", "jobs": [hr.job_card(_job())]}}
    sess = FakeSession(session_id="s1", messages=[{"role": "user", "content": "q"}, reply])
    monkeypatch.setattr(hr, "_load_session", lambda sid: sess)
    return sess, reply


def test_a_finished_job_collapses_its_card_and_posts_the_result(monkeypatch):
    sess, reply = _started_reply(monkeypatch)
    sent, posted = _events(monkeypatch), []
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(kw["text"]) or {})
    monkeypatch.setattr(hr, "_run_hidden_turn", lambda node, sid, summary, job_id=None: "Flights from $139.")
    node = {"id": "bg", "label": "Long Running", "model": "m", "deliver": "speak_or_notify"}
    assert hr.background_runner(node, "s1")(escalation.get_job("j1")) == "Flights from $139."
    card = reply["_meta"]["jobs"][0]
    assert card["status"] == "done" and card["completed_at"] and posted == ["Flights from $139."]
    assert sent[-1][1]["status"] == "done" and sess.saves >= 1


def test_a_failed_job_says_so_on_its_card(monkeypatch):
    _, reply = _started_reply(monkeypatch)
    _events(monkeypatch)
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: {})

    def boom(*a, **kw):
        raise RuntimeError("quota")

    monkeypatch.setattr(hr, "_run_hidden_turn", boom)
    hr.background_runner({"id": "bg", "model": "m", "deliver": "post"}, "s1")(escalation.get_job("j1"))
    assert reply["_meta"]["jobs"][0]["status"] == "failed"
    assert escalation.get_job("j1")["status"] == "failed"


def test_a_stopped_job_posts_nothing(monkeypatch):
    _, reply = _started_reply(monkeypatch)
    _events(monkeypatch)
    posted = []
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(kw) or {})

    def stopped_midway(node, sid, summary, job_id=None):
        escalation.update_job(job_id, stop_requested=True)
        return "Cancelled by user"

    monkeypatch.setattr(hr, "_run_hidden_turn", stopped_midway)
    out = hr.background_runner({"id": "bg", "model": "m", "deliver": "speak_or_notify"}, "s1")(
        escalation.get_job("j1"))
    assert out == "" and posted == [] and reply["_meta"]["jobs"][0]["status"] == "stopped"


def test_stop_job_cancels_the_hidden_turn(monkeypatch):
    cancelled = []
    import api.streaming as streaming
    monkeypatch.setattr(streaming, "cancel_stream", lambda sid: cancelled.append(sid) or True)
    _job(stream_id="hidden-1")
    assert hr.stop_job("s2", "j1") is False          # another chat's job
    assert hr.stop_job("s1", "nope") is False
    assert hr.stop_job("s1", "j1") is True
    assert cancelled == ["hidden-1"] and escalation.get_job("j1")["stop_requested"] is True
    escalation.update_job("j1", status="done")
    assert hr.stop_job("s1", "j1") is False          # already over


def test_old_runner_calls_without_a_job_id_still_work(monkeypatch):
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: {})
    monkeypatch.setattr(hr, "_run_hidden_turn", lambda node, sid, summary, job_id=None: "ok")
    assert hr.background_runner({"id": "c", "model": "m", "deliver": "speak_or_notify"}, "s1")(
        {"summary": "x"}) == "ok"


def test_after_jobs_tell_the_registry_which_node_they_run():
    seen = []

    def fake_start(**kw):
        seen.append(kw.get("parent"))
        return "j9"

    plan = SimpleNamespace(after=[({"id": "bg", "type": "background", "label": "Long Running", "model": "m"},
                                   "always")])
    import unittest.mock as mock
    with mock.patch.object(escalation, "start_escalation", side_effect=fake_start):
        assert hr.start_after_jobs(plan, session_id="s1", question="q", answer="a",
                                   elapsed_s=1, tool_count=0) == ["j9"]
    assert seen == [{"node_id": "bg", "node_label": "Long Running", "kind": "background"}]


def test_start_turn_jobs_puts_this_turns_cards_on_the_reply(monkeypatch):
    sent = _events(monkeypatch)
    monkeypatch.setattr(hr, "_start_job", lambda sid, node, runner, **kw: _job("bg1", started_at=200.0)["job_id"])
    reply = {"role": "assistant", "content": "On it.", "_meta": {"kind": "answer"}}
    sess = FakeSession(session_id="s1", messages=[reply])
    plan = SimpleNamespace(after=[({"id": "bg", "type": "background", "model": "m"}, "always")])
    hr.start_turn_jobs(plan, sess, reply, session_id="s1", question="q", answer="On it.",
                       elapsed_s=1, tool_count=0, since=150.0)
    assert [j["id"] for j in reply["_meta"]["jobs"]] == ["bg1"] and sent


def test_a_job_that_ends_before_its_card_is_attached_shows_ended(monkeypatch):
    _events(monkeypatch)
    reply = {"role": "assistant", "content": "On it.", "_meta": {}}
    sess = FakeSession(session_id="s1", messages=[reply])
    stale = hr.job_card(_job())
    escalation.update_job("j1", status="done", completed_at=130.0)
    hr.attach_job_cards(sess, reply, [stale])
    assert reply["_meta"]["jobs"][0]["status"] == "done"


def test_streaming_wires_the_cards_into_the_turn():
    from pathlib import Path
    src = (Path(__file__).resolve().parents[1] / "api" / "streaming.py").read_text()
    bind = src[src.index("_esc.bind_turn_context("):]
    assert "job_node(" in bind[:bind.index(")\n")]          # hand-off jobs know their node
    after = src[src.index("start_turn_jobs("):]
    assert after.index("start_turn_jobs(") < after.index("put('turn_meta'")  # cards ride the turn_meta


def test_a_compacted_chat_keeps_its_job(monkeypatch):
    """Compression gives the chat a new session id mid-turn: the card lands on
    the new one, so the job's events, result and Stop must follow it there."""
    sent, posted = _events(monkeypatch), []
    _job(session_id="old")
    reply = {"role": "assistant", "content": "On it.", "_meta": {}}
    new = FakeSession(session_id="new", messages=[reply])
    hr.attach_job_cards(new, reply, [hr.job_card(escalation.get_job("j1"))])
    assert escalation.get_job("j1")["session_id"] == "new"
    monkeypatch.setattr(hr, "_load_session", lambda sid: new if sid == "new" else FakeSession(messages=[]))
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(sid) or {})
    monkeypatch.setattr(hr, "_run_hidden_turn", lambda node, sid, summary, job_id=None: "done")
    hr.background_runner({"id": "bg", "model": "m", "deliver": "post"}, "old")(escalation.get_job("j1"))
    assert posted == ["new"] and reply["_meta"]["jobs"][0]["status"] == "done"
    assert {sid for sid, _ in sent} == {"new"}
    assert hr.stop_job("old", "j1") is False


def test_stop_reads_the_stream_after_flagging(monkeypatch):
    """Stop lands while the hidden turn registers its stream: the flag goes in
    first and the stream id is read after, so the cancel is never missed."""
    cancelled = []
    import api.streaming as streaming
    monkeypatch.setattr(streaming, "cancel_stream", lambda sid: cancelled.append(sid) or True)
    _events(monkeypatch)
    _job()
    real = escalation.get_job

    def get_then_register(job_id):
        job = real(job_id)
        escalation.update_job(job_id, stream_id="hidden-late")   # registered right after the read
        return job

    monkeypatch.setattr(escalation, "get_job", get_then_register)
    assert hr.stop_job("s1", "j1") is True
    assert cancelled == ["hidden-late"]


def test_stop_shows_stopping_and_only_stops_background_jobs(monkeypatch):
    sent = _events(monkeypatch)
    import api.streaming as streaming
    monkeypatch.setattr(streaming, "cancel_stream", lambda sid: True)
    _job()
    _job("rev", parent={"node_id": "r", "kind": "review"})
    assert hr.stop_job("s1", "rev") is False
    assert hr.stop_job("s1", "j1") is True
    assert sent[-1][1]["stopping"] is True
    assert hr.job_card(escalation.get_job("j1"))["stopping"] is True


# ── HTTP ─────────────────────────────────────────────────────────────────────

def test_jobs_endpoints(monkeypatch, tmp_path):
    from api.harness_routes import handle_harness_request
    from api.harness_store import HarnessStore
    import api.streaming as streaming
    monkeypatch.setattr(streaming, "cancel_stream", lambda sid: True)
    _job(stream_id="h")
    st = HarnessStore(tmp_path)
    status, body = handle_harness_request("GET", "/jobs/s1", None, st)
    assert status == 200 and [j["id"] for j in body["jobs"]] == ["j1"]
    assert handle_harness_request("POST", "/jobs/s1/j1/stop", {}, st) == (200, {"ok": True})
    assert handle_harness_request("POST", "/jobs/s1/zz/stop", {}, st)[0] == 404


def test_a_background_turn_carries_the_users_latest_words():
    """The Mac-browser gate reads the turn's text: a hidden turn must carry the
    parent chat's latest user message, not only the hand-off note."""
    msgs = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "Here."},
            {"role": "user", "content": [{"type": "text", "text": "open kayak in my browser"}]},
            {"role": "assistant", "content": "On it."}]
    prompt = hr.hidden_turn_prompt("", msgs)
    assert "open kayak in my browser" in prompt and prompt.startswith("A faster model handed this over")
    assert "Hand-off note: check prices" in hr.hidden_turn_prompt("check prices", msgs[:2])
