"""Jarvis's own approvals (a dangerous command, a send card) as Agents requests:
answerable from the Agents screen, the push, the Background job's card in the
chat, and the chat card itself — whichever comes first. Plus the job's own chat
view: the live event feed, the saved transcript and /view."""
from __future__ import annotations

import os
import sys
import time

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import pytest  # noqa: E402

import api.config  # noqa: E402,F401
from api import agent_hooks  # noqa: E402
from api import coding_permission as cp  # noqa: E402
from api import harness_runner as hr  # noqa: E402
from api import jarvis_approvals as ja  # noqa: E402
from agent import escalation  # noqa: E402

WORKER = "chat1~bg"
CMD = {"command": "rm -rf /root/build", "description": "recursive delete",
       "pattern_key": "rm_rf", "pattern_keys": ["rm_rf"]}


@pytest.fixture(autouse=True)
def env(monkeypatch):
    cp._reset_for_tests()
    ja._reset_for_tests()
    escalation.reset_for_tests()
    pushes, answers, published = [], [], []
    monkeypatch.setattr(agent_hooks, "_push_agent_alert", lambda **kw: pushes.append(kw) or 1)
    monkeypatch.setattr(agent_hooks, "_device_channels", lambda: [])
    monkeypatch.setattr(agent_hooks, "_agent_la_tick", lambda: None)
    monkeypatch.setattr(hr, "_publish_job", lambda sid, card: published.append((sid, dict(card))))

    def fake_respond(sid, choice, approval_id=""):
        answers.append((sid, choice, approval_id))
        ja.answered(sid, approval_id)
        return 1

    import api.approvals as approvals
    monkeypatch.setattr(approvals, "respond_approval", fake_respond)
    yield pushes, answers, published
    cp._reset_for_tests()
    ja._reset_for_tests()
    escalation.reset_for_tests()


def _job(job_id="j1", session_id="chat1", **extra):
    job = {"job_id": job_id, "session_id": session_id, "reason": "harness:bg", "summary": "dig in",
           "model": "m", "status": "running", "started_at": 100.0, "completed_at": None,
           "worker_session": WORKER,
           "parent": {"node_id": "bg", "node_label": "Long Running", "kind": "background",
                      "question": "Research small modular reactors"}}
    job.update(extra)
    with escalation._lock:
        escalation._jobs[job_id] = job
    return job


def test_background_job_approval_is_an_agents_request_with_a_push(env):
    pushes, _answers, _ = env
    fp = ja.announce(WORKER, CMD)
    items = cp.list_pending()
    assert len(items) == 1
    req = items[0]
    assert req["fingerprint"] == fp and req["agent"] == "jarvis"
    assert req["can_always"] is True
    assert req["key"].endswith(f"|jarvis|{WORKER}")
    assert len(pushes) == 1 and pushes[0]["title"] == "Jarvis needs approval"
    assert "rm -rf /root/build" in pushes[0]["body"]


def test_chat_turn_approval_is_quiet_while_the_chat_is_open(env, monkeypatch):
    pushes, _answers, _ = env
    from api.session_events import SESSION_EVENTS
    monkeypatch.setattr(SESSION_EVENTS, "subscriber_count", lambda sid: 1)
    ja.announce("chat1", CMD)
    assert len(cp.list_pending()) == 1
    assert pushes == []          # the chat already shows its card


def test_chat_nobody_has_open_gets_the_push(env, monkeypatch):
    pushes, _answers, _ = env
    from api.session_events import SESSION_EVENTS
    monkeypatch.setattr(SESSION_EVENTS, "subscriber_count", lambda sid: 0)
    ja.announce("chat1", CMD)
    assert len(pushes) == 1


def test_agents_decision_answers_the_waiting_turn(env):
    _pushes, answers, _ = env
    ja.announce(WORKER, CMD)
    rid = cp.list_pending()[0]["request_id"]
    assert cp.resolve(rid, decision="allow") is True
    assert answers == [(WORKER, "once", "")]
    assert ja.open_for(WORKER) == [] and cp.list_pending() == []


def test_agents_always_and_deny_map_to_gateway_choices(env):
    _pushes, answers, _ = env
    ja.announce(WORKER, CMD)
    cp.resolve(cp.list_pending()[0]["request_id"], decision="always")
    ja.announce(WORKER, CMD)
    cp.resolve(cp.list_pending()[0]["request_id"], decision="deny")
    assert [a[1] for a in answers] == ["always", "deny"]


def test_answer_in_chat_clears_the_agents_request(env):
    ja.announce("chat1", {"kind": "send", "approval_id": "a1", "command": "text Mom",
                          "description": "Send to Mom"})
    ja.announce("chat1", CMD)
    ja.answered("chat1", "a1")
    left = ja.open_for("chat1")
    assert [d.get("command") for d in left] == [CMD["command"]]
    assert len(cp.list_pending()) == 1


def test_turn_end_clears_everything(env):
    ja.announce(WORKER, CMD)
    ja.announce(WORKER, CMD)
    ja.clear(WORKER)
    assert ja.open_for(WORKER) == [] and cp.list_pending() == []


def test_unknown_fingerprint_is_not_ours(env):
    fp = ja.announce(WORKER, CMD)
    assert ja.owns(fp) and not ja.owns("codex:1") and not ja.owns(None)
    assert ja.decide("jarvis:gone:1", "allow") is False


def test_request_fingerprint_matches_the_trackers_row(env):
    """The Live Activity's buttons carry the row's fingerprint."""
    from agent.agent_engine_shim import fingerprint
    fp = ja.announce(WORKER, CMD)
    data = ja.open_for(WORKER)[0]
    assert fp == fingerprint(WORKER, data["_token"], "terminal", {"command": CMD["command"]})


def test_an_answer_names_its_ask(env):
    """Two asks waiting: Allow on the second releases the second, not the oldest."""
    _p, answers, _ = env
    ja.announce(WORKER, dict(CMD, approval_id="a1", command="rm -rf /a"))
    fp_b = ja.announce(WORKER, dict(CMD, approval_id="b2", command="rm -rf /b"))
    assert ja.decide(fp_b, "allow") is True
    assert answers == [(WORKER, "once", "b2")]
    assert [d["command"] for d in ja.open_for(WORKER)] == ["rm -rf /a"]


def test_an_answer_for_an_ask_no_longer_open_retires_nothing_else(env):
    ja.announce(WORKER, dict(CMD, approval_id="a1"))
    ja.answered(WORKER, "zz")
    assert len(ja.open_for(WORKER)) == 1


def test_gateway_settling_an_ask_clears_every_copy(env):
    """Answered elsewhere or timed out: the gateway says so and the copies go."""
    _job()
    ja.announce(WORKER, dict(CMD, approval_id="a1"))
    ja._settled(WORKER, {"approval_id": "a1"})
    assert ja.open_for(WORKER) == [] and cp.list_pending() == []
    assert hr.job_card(escalation.get_job("j1"))["approval"] is None


def test_ask_puts_the_request_back(env):
    fp = ja.announce(WORKER, CMD)
    rid = cp.list_pending()[0]["request_id"]
    assert cp.resolve(rid, decision="ask") is True
    assert [r["fingerprint"] for r in cp.list_pending()] == [fp]
    assert ja.open_for(WORKER)


def test_gateway_never_releases_another_ask_for_a_stale_id():
    import threading
    from tools import approval
    entry = approval._ApprovalEntry({"command": "x", "approval_id": "live"})
    with approval._lock:
        approval._gateway_queues["s-stale"] = [entry]
    try:
        assert approval.resolve_gateway_approval("s-stale", "once", approval_id="gone") == 0
        assert not entry.event.is_set()
        assert approval.resolve_gateway_approval("s-stale", "once", approval_id="live") == 1
    finally:
        with approval._lock:
            approval._gateway_queues.pop("s-stale", None)


def test_job_card_carries_the_approval_until_answered(env):
    _p, _a, published = env
    _job()
    ja.announce(WORKER, CMD)
    card = hr.job_card(escalation.get_job("j1"))
    assert card["approval"]["session_id"] == WORKER
    assert card["approval"]["kind"] == "command" and card["approval"]["can_always"]
    assert card["activity"] == "Needs your approval"
    assert card["worker_session"] == WORKER
    ja.answered(WORKER)
    card = hr.job_card(escalation.get_job("j1"))
    assert card["approval"] is None
    assert published  # the devices heard both changes


def test_ended_job_card_has_no_approval(env):
    _job(status="done", approval={"session_id": WORKER})
    assert hr.job_card(escalation.get_job("j1"))["approval"] is None


def test_request_ttl_outlives_the_default(env, monkeypatch):
    rid = cp.create_request(tool="terminal", summary="x", session_id="s", cwd="",
                            fingerprint="jarvis:s:1", ttl=400)
    real = time.time
    monkeypatch.setattr(cp.time, "time", lambda: real() + 200)
    assert any(r["request_id"] == rid for r in cp.list_pending())
    monkeypatch.setattr(cp.time, "time", lambda: real() + 500)
    assert not any(r["request_id"] == rid for r in cp.list_pending())


# ── the job's chat view ──────────────────────────────────────────────────────

def test_feed_merges_unread_tokens_and_strips_the_session():
    f = hr._JobFeed()
    f.add("token", {"text": "Hel"})
    f.add("token", {"text": "lo"})
    f.add("metering", {"x": 1})            # not a chat event
    f.add("tool", {"name": "terminal"})
    f.add("done", {"session": {"messages": [1, 2]}, "usage": {"t": 1}})
    events, _cursor, closed = f.read(None, 0)
    assert [e for e, _ in events] == ["token", "tool", "done"]
    assert events[0][1]["text"] == "Hello"
    assert "session" not in events[2][1] and events[2][1]["usage"] == {"t": 1}
    assert closed is False


def test_a_watching_reader_gets_only_the_new_text():
    """Tokens always merge (a watched job stays small); each reader keeps its place."""
    f = hr._JobFeed()
    f.add("token", {"text": "a"})
    events, cursor, _ = f.read(None, 0)
    f.add("token", {"text": "b"})
    f.add("token", {"text": "c"})
    more, cursor, _ = f.read(cursor, 0)
    assert [d["text"] for _, d in events + more] == ["a", "bc"]
    assert len(f.events) == 1
    late, _c, _ = f.read(None, 0)          # a viewer opening now gets it whole
    assert late == [("token", {"text": "abc"})]
    f.add("tool", {"name": "terminal"})
    f.add("token", {"text": "d"})
    more, cursor, _ = f.read(cursor, 0)
    assert more == [("tool", {"name": "terminal"}), ("token", {"text": "d"})]
    f.close()
    assert f.read(cursor, 0)[0] == [] and f.read(cursor, 0)[2] is True


def test_final_events_are_kept_past_the_cap(monkeypatch):
    monkeypatch.setattr(hr, "_FEED_MAX", 2)
    f = hr._JobFeed()
    for i in range(4):
        f.add("tool", {"name": str(i)})
    f.add("done", {})
    assert [e for e, _ in f.events] == ["tool", "tool", "done"]


def test_watch_progress_fills_and_closes_the_feed(monkeypatch):
    import queue
    _job()
    q = queue.Queue()
    for ev in (("token", {"text": "hi"}), ("tool", {"name": "web_search", "event_type": "tool.started"}),
               ("done", {"session": {}})):
        q.put(ev)
    hr._watch_progress(q, "chat1", "j1")
    feed = hr.job_feed("j1")
    events, _c, closed = feed.read(None, 0)
    assert [e for e, _ in events] == ["token", "tool", "done"] and closed


def test_transcript_round_trip_and_view(tmp_path, monkeypatch):
    monkeypatch.setattr(hr, "_transcript_dir", lambda: tmp_path)
    _job(status="done", completed_at=200.0)
    msgs = [{"role": "assistant", "content": "", "tool_calls": [{"id": "c1"}]},
            {"role": "tool", "tool_call_id": "c1", "content": "ok"},
            {"role": "assistant", "content": "Done."}]
    hr._save_transcript("j1", "chat1", "Research small modular reactors", msgs)
    view = hr.job_view("chat1", "j1")
    assert view["task"] == "Research small modular reactors"
    assert view["messages"][-1]["content"] == "Done."
    assert view["running"] is False and view["job"]["id"] == "j1"
    assert hr.job_view("other-chat", "j1") is None
    assert hr.job_view("chat1", "nope") is None


def test_transcript_rejects_unsafe_ids(tmp_path, monkeypatch):
    monkeypatch.setattr(hr, "_transcript_dir", lambda: tmp_path)
    hr._save_transcript("../evil", "chat1", "t", [])
    assert list(tmp_path.iterdir()) == []
    assert hr._load_transcript("../evil") is None


def test_running_view_has_task_and_no_messages(tmp_path, monkeypatch):
    monkeypatch.setattr(hr, "_transcript_dir", lambda: tmp_path)
    _job()
    view = hr.job_view("chat1", "j1")
    assert view["running"] is True and view["messages"] == []
    assert view["task"] == "Research small modular reactors"
