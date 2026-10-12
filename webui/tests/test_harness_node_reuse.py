"""A Background node's jobs run on one warm agent per (chat, node).

Each job used to build a throwaway session holding a copy of the chat's DISPLAY
transcript, run a fresh agent on it and delete it all afterwards, so every job
paid a full cold prompt-cache write. Now a job runs on a hidden worker session
with a stable id, seeded from the chat's COMPACTED context, whose cached agent
stays warm between jobs (the agent cache bounds it). Two jobs for the same
worker take turns; Stop still cancels; only the result reaches the chat.
"""
import copy
import threading
import time
from types import SimpleNamespace

import pytest

import api.config as cfg
import api.harness_runner as hr
import api.models as models
import api.streaming as streaming
from agent import escalation

DISPLAY = [
    {"role": "user", "content": "Find me flights to Lisbon"},
    {"role": "assistant", "content": "Looking.", "_meta": {"kind": "answer"}},
    {"role": "user", "content": "In May"},
    {"role": "assistant", "content": "On it.", "_meta": {"kind": "answer"}},
]
CONTEXT = [
    {"role": "user", "content": "[summary] He wants May flights to Lisbon."},
    {"role": "assistant", "content": "On it."},
]
NODE = {"id": "bg", "type": "background", "label": "Long Running",
        "model": "@anthropic-api:claude-sonnet-5-5", "deliver": "post"}


@pytest.fixture
def chat(monkeypatch, tmp_path):
    """A saved chat with a compacted context, and a stand-in for the streaming
    worker that does what the real one does with the session and the agent
    cache: load the session, plan the node, get-or-build the cached agent,
    take the model-facing history, run, write the turn back."""
    monkeypatch.setattr(models, "SESSION_DIR", tmp_path)
    monkeypatch.setattr(cfg, "SESSION_DIR", tmp_path)
    monkeypatch.setattr(models, "SESSION_INDEX_FILE", tmp_path / "_index.json")
    monkeypatch.setattr(hr, "_publish_job", lambda sid, card: None)
    escalation.reset_for_tests()
    parent = models.Session(session_id="p1", workspace=str(tmp_path),
                            messages=copy.deepcopy(DISPLAY), context_messages=copy.deepcopy(CONTEXT))
    parent.save()

    st = SimpleNamespace(calls=[], built=[], gate=None, entered=threading.Event(),
                         active=0, peak=0, during=None, lock=threading.Lock(), db_rows=[])

    class _StateDB:
        """Records what the agent writes to state.db (session search, the
        device-tool usage ranking read it)."""

        def append_message(self, **row):
            st.db_rows.append(row)

        def close(self):
            pass

    def fake_run(sid, prompt, model, workspace, stream_id, attachments=None, **kw):
        s = models.get_session(sid)
        plan = streaming._plan_for_turn(s, prompt, attachments)
        key = plan.cache_key(sid)
        with cfg.SESSION_AGENT_CACHE_LOCK:
            entry = cfg.SESSION_AGENT_CACHE.get(key)
            if entry is None:
                entry = (SimpleNamespace(_session_db=_StateDB(), _session_db_created=True,
                                         _last_flushed_db_idx=0, session_id=sid,
                                         _apply_persist_user_message_override=lambda m: None), "sig")
                st.built.append(entry[0])
                cfg.SESSION_AGENT_CACHE[key] = entry
            cfg.SESSION_AGENT_CACHE.move_to_end(key)
        history = copy.deepcopy(streaming._context_messages_for_new_turn(s, prompt))
        with st.lock:
            st.active += 1
            st.peak = max(st.peak, st.active)
        st.calls.append({"sid": sid, "agent": entry[0], "history": history, "stream_id": stream_id,
                         "listed": {r["session_id"] for r in models.all_sessions()}})
        st.entered.set()
        try:
            if st.during:
                st.during(sid, stream_id)
            if st.gate is not None:
                st.gate.wait(5)
            s.save()
            steps = [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": "", "tool_calls": [
                    {"id": "t1", "type": "function", "function": {"name": "web_search", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "t1", "content": "TAP $139, Ryanair $152"},
                {"role": "assistant", "content": f"Flights from $139 ({len(st.calls)})."},
            ]
            # The agent's own end-of-run state.db write (run_agent's flush).
            from run_agent import AIAgent
            AIAgent._flush_messages_to_session_db(entry[0], list(history) + steps, history)
            s.messages = list(s.messages) + steps
            s.context_messages = list(history) + steps
            s.save()
        finally:
            with st.lock:
                st.active -= 1

    monkeypatch.setattr(streaming, "_run_agent_streaming", fake_run)
    yield SimpleNamespace(parent=parent, st=st, dir=tmp_path)
    escalation.reset_for_tests()
    with cfg.LOCK:
        for sid in [k for k in models.SESSIONS if str(k).startswith("p1")]:
            models.SESSIONS.pop(sid, None)
    cfg.evict_session_agents("p1")


def _job(job_id="j1", session_id="p1"):
    job = {"job_id": job_id, "session_id": session_id, "reason": "harness:bg", "summary": "find flights",
           "model": NODE["model"], "status": "running", "started_at": time.time(),
           "completed_at": None, "text": None,
           "parent": {"node_id": "bg", "node_label": "Long Running", "kind": "background"}}
    with escalation._lock:
        escalation._jobs[job_id] = job
    return job


def test_worker_id_is_stable_hidden_and_not_a_chat_id():
    wid = hr.worker_session_id("p1", "bg")
    assert wid == hr.worker_session_id("p1", "bg")
    assert wid != hr.worker_session_id("p1", "other") != hr.worker_session_id("p2", "bg")
    assert models.is_worker_session_id(wid)
    assert not models.is_worker_session_id("p1")
    assert models.Session.load(wid) is None        # never read from disk


def test_worker_reuses_agent_across_jobs(chat):
    first = hr._run_hidden_turn(NODE, "p1", "find flights")
    second = hr._run_hidden_turn(NODE, "p1", "find flights")

    assert first and second
    sids = {c["sid"] for c in chat.st.calls}
    assert sids == {hr.worker_session_id("p1", "bg")}
    assert chat.st.calls[0]["agent"] is chat.st.calls[1]["agent"]
    assert len(chat.st.built) == 1
    # Still warm after the job: the agent cache, not the job, decides when it goes.
    with cfg.SESSION_AGENT_CACHE_LOCK:
        assert any(e[0] is chat.st.built[0] for e in cfg.SESSION_AGENT_CACHE.values())


def test_worker_seeds_compacted_context(chat):
    hr._run_hidden_turn(NODE, "p1", "find flights")
    hr._run_hidden_turn(NODE, "p1", "find flights")

    for call in chat.st.calls:
        # The chat's model-facing history, never the display transcript, and
        # never an earlier job's working steps.
        assert call["history"] == CONTEXT
        assert not any(m.get("role") == "tool" for m in call["history"])


def test_worker_without_compacted_context_starts_from_the_messages(chat):
    plain = models.Session(session_id="p1b", workspace=str(chat.dir), messages=copy.deepcopy(CONTEXT))
    plain.save()
    try:
        hr._run_hidden_turn(NODE, "p1b", "find flights")
        assert chat.st.calls[0]["history"] == CONTEXT
    finally:
        cfg.evict_session_agents("p1b")
        with cfg.LOCK:
            models.SESSIONS.pop("p1b", None)


def test_every_jobs_steps_reach_state_db_on_a_reused_agent(chat):
    """Job N leaves the agent's flush cursor past job N+1's (shorter) seed; a
    reused worker agent must still write all of job N+1's messages."""
    hr._run_hidden_turn(NODE, "p1", "find flights")
    first = len(chat.st.db_rows)
    hr._run_hidden_turn(NODE, "p1", "find flights")

    assert len(chat.st.built) == 1                          # the same agent both times
    second = chat.st.db_rows[first:]
    assert first == 4 and len(second) == 4
    assert second[0]["role"] == "user"                      # starts at the job's own message
    assert any(r.get("tool_calls") for r in second) and any(r["role"] == "tool" for r in second)


def test_worker_not_listed_and_leaves_no_file(chat):
    wid = hr.worker_session_id("p1", "bg")
    hr._run_hidden_turn(NODE, "p1", "find flights")

    assert wid not in chat.st.calls[0]["listed"]           # not even while it runs
    assert "p1" in chat.st.calls[0]["listed"]
    assert not (chat.dir / f"{wid}.json").exists()
    assert not any(models.WORKER_SESSION_SEP in p.name for p in chat.dir.iterdir())
    assert wid not in {r["session_id"] for r in models.all_sessions()}
    with pytest.raises(KeyError):
        models.get_session(wid)


def test_background_jobs_serialize_per_node(chat):
    """Two overlapping jobs for the same chat+node take turns on the warm
    agent; a job on another node does not wait for them."""
    chat.st.gate = threading.Event()
    results = {}

    def run(name, node):
        results[name] = hr._run_hidden_turn(node, "p1", "find flights")

    a = threading.Thread(target=run, args=("a", NODE))
    a.start()
    assert chat.st.entered.wait(5)
    b = threading.Thread(target=run, args=("b", NODE))
    b.start()
    time.sleep(0.3)
    assert len(chat.st.calls) == 1                          # b waits for a's lock

    other = dict(NODE, id="bg2")
    c = threading.Thread(target=run, args=("c", other))
    c.start()
    deadline = time.time() + 5
    while len(chat.st.calls) < 2 and time.time() < deadline:
        time.sleep(0.02)
    assert chat.st.calls[1]["sid"] == hr.worker_session_id("p1", "bg2")

    chat.st.gate.set()
    for t in (a, b, c):
        t.join(10)
    assert set(results) == {"a", "b", "c"} and all(results.values())
    same = [c for c in chat.st.calls if c["sid"] == hr.worker_session_id("p1", "bg")]
    assert len(same) == 2 and same[0]["agent"] is same[1]["agent"]
    cfg.evict_session_agents("p1")


def test_stop_cancels_worker_job(chat, monkeypatch):
    cancelled = []
    monkeypatch.setattr(streaming, "cancel_stream", lambda sid: cancelled.append(sid) or True)
    posted = []
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(kw) or {})
    job = _job()
    chat.st.during = lambda sid, stream_id: hr.stop_job("p1", "j1")

    out = hr.background_runner(NODE, "p1")(escalation.get_job("j1"))

    assert cancelled == [chat.st.calls[0]["stream_id"]]   # the worker's own stream
    assert out == "" and posted == []
    assert escalation.get_job(job["job_id"])["status"] == "stopped"


def test_stop_while_waiting_for_the_worker_skips_the_job(chat, monkeypatch):
    monkeypatch.setattr(streaming, "cancel_stream", lambda sid: True)
    chat.st.gate = threading.Event()
    first = threading.Thread(target=hr._run_hidden_turn, args=(NODE, "p1", "find flights"))
    first.start()
    assert chat.st.entered.wait(5)

    _job("j2")
    out = {}
    queued = threading.Thread(target=lambda: out.setdefault("text", hr._run_hidden_turn(
        NODE, "p1", "find flights", job_id="j2")))
    queued.start()
    time.sleep(0.2)
    assert hr.stop_job("p1", "j2")
    queued.join(5)
    assert not queued.is_alive() and out["text"] == ""
    assert len(chat.st.calls) == 1                          # the queued job never ran
    chat.st.gate.set()
    first.join(10)


def test_result_only_lands_in_chat(chat):
    _job()
    before = len(chat.parent.messages)

    hr.background_runner(NODE, "p1")(escalation.get_job("j1"))

    s = models.get_session("p1")
    added = s.messages[before:]
    assert [m["role"] for m in added] == ["assistant"]
    assert added[0]["content"].startswith("Flights from $139")
    assert added[0]["_meta"]["kind"] == "background"
    for m in list(s.messages) + list(s.context_messages):
        assert m.get("role") != "tool" and not m.get("tool_calls")
    assert escalation.get_job("j1")["status"] == "done"
