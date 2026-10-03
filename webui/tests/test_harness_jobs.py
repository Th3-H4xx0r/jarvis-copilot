from types import SimpleNamespace

import api.harness_runner as hr


class FakeSession(SimpleNamespace):
    def save(self, **kw):
        self.saved = True


def _wire(monkeypatch, sess, listeners=0, push=None):
    monkeypatch.setattr(hr, "_load_session", lambda sid: sess)
    monkeypatch.setattr(hr, "_listener_count", lambda sid: listeners)
    monkeypatch.setattr(hr, "_push_alert", push or (lambda *a: 1))


def test_deliver_without_listeners_saves_and_pushes(monkeypatch):
    sess, pushed = FakeSession(session_id="s1", messages=[], context_messages=[{"role": "user", "content": "q"}]), []
    _wire(monkeypatch, sess, 0, lambda title, body, sid: pushed.append((title, sid)) or 1)
    msg = hr.deliver_result("s1", node={"id": "claude", "model": "@claude-code:claude-sonnet-5-5",
                                        "deliver": "speak_or_notify"}, kind="background", text="Done: $89", ms=41000)
    assert sess.messages[-1]["content"] == "Done: $89" and sess.messages[-1]["_meta"]["kind"] == "background"
    assert sess.context_messages[-1]["content"] == "Done: $89"
    assert sess.saved and pushed == [("Claude finished", "s1")]
    assert msg["_meta"]["model"] == "@claude-code:claude-sonnet-5-5"


def test_deliver_with_listener_does_not_push(monkeypatch):
    sess, pushed = FakeSession(session_id="s1", messages=[]), []
    _wire(monkeypatch, sess, 1, lambda *a: pushed.append(a) or 1)
    hr.deliver_result("s1", node={"id": "c", "model": "m", "deliver": "speak_or_notify"},
                      kind="background", text="x", ms=1)
    assert pushed == []


def test_post_delivery_never_pushes(monkeypatch):
    sess, pushed = FakeSession(session_id="s1", messages=[]), []
    _wire(monkeypatch, sess, 0, lambda *a: pushed.append(a) or 1)
    hr.deliver_result("s1", node={"id": "c", "model": "m", "deliver": "post"}, kind="background", text="x", ms=1)
    assert pushed == [] and sess.messages


def test_push_failure_is_swallowed(monkeypatch):
    sess = FakeSession(session_id="s1", messages=[])

    def boom(*a):
        raise RuntimeError("apns down")

    _wire(monkeypatch, sess, 0, boom)
    hr.deliver_result("s1", node={"id": "c", "model": "m", "deliver": "notify"}, kind="background", text="x", ms=1)
    assert sess.messages


def test_review_ok_posts_nothing_fix_posts(monkeypatch):
    posted = []
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(kw["text"]) or {})
    node = {"id": "check", "model": "m", "deliver": "post_if_changed"}
    monkeypatch.setattr(hr, "_one_shot", lambda ref, prompt, max_tokens=600: '{"verdict": "ok", "text": ""}')
    assert hr.review_runner(node, "s1", "q", "a")({}) == "" and posted == []
    monkeypatch.setattr(hr, "_one_shot",
                        lambda ref, prompt, max_tokens=600: 'Sure: {"verdict": "fix", "text": "Actually 3."}')
    assert hr.review_runner(node, "s1", "q", "a")({}) == "Actually 3." and posted == ["Actually 3."]


def test_background_failure_posts_a_short_note(monkeypatch):
    posted = []
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: posted.append(kw) or {})

    def boom(*a):
        raise RuntimeError("quota")

    monkeypatch.setattr(hr, "_run_hidden_turn", boom)
    text = hr.background_runner({"id": "c", "model": "m", "deliver": "speak_or_notify"}, "s1")({"summary": "x"})
    assert "Couldn't finish" in text and posted[0]["error"]


def test_after_jobs_respect_conditions(monkeypatch):
    started = []
    monkeypatch.setattr(hr, "_start_job", lambda sid, node, runner: started.append(node["id"]) or node["id"])
    plan = SimpleNamespace(after=[({"id": "a", "type": "review", "model": "m"}, "always"),
                                  ({"id": "b", "type": "background", "model": "m"}, "slow:30"),
                                  ({"id": "c", "type": "background", "model": "m"}, "tools:3")])
    hr.start_after_jobs(plan, session_id="s1", question="q", answer="a", elapsed_s=10, tool_count=5)
    assert started == ["a", "c"]


def test_late_harness_results_survive_the_turn_writeback():
    from api.streaming import _carry_late_harness_results
    prev = [{"role": "user", "content": "q1"}, {"role": "assistant", "content": "a1"}]
    bg = {"role": "assistant", "content": "Claude: done", "_meta": {"kind": "background"}}
    current = prev + [bg]
    merged = prev + [{"role": "user", "content": "q2"}, {"role": "assistant", "content": "a2"}]
    assert _carry_late_harness_results(current, len(prev), merged) == merged + [bg]
    assert _carry_late_harness_results(prev, len(prev), merged) == merged


def test_turn_stamp_skips_carried_background_replies():
    from api.streaming import _last_turn_assistant
    answer = {"role": "assistant", "content": "turn 2 answer"}
    bg = {"role": "assistant", "content": "claude", "_meta": {"kind": "background"}}
    msgs = [{"role": "user", "content": "q"}, answer, bg]
    assert _last_turn_assistant(msgs) is answer
    assert _last_turn_assistant([{"role": "user", "content": "q"}]) is None
