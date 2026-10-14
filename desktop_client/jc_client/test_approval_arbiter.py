"""The approval arbiter: a blocked PermissionRequest / AskUserQuestion hook
waits here until the island or the phone decides — or it is settled elsewhere.
A decision only ever answers the exact request it was made for."""
import pytest

from jc_client import agent_engine as ae
from jc_client.approval_arbiter import Arbiter


class Timers:
    """Deterministic stand-in for threading.Timer."""

    def __init__(self):
        self.made = []

    def __call__(self, delay, fn, args=()):
        t = _T(delay, fn, args)
        self.made.append(t)
        return t


class _T:
    def __init__(self, delay, fn, args):
        self.delay, self.fn, self.args = delay, fn, args
        self.cancelled = False
        self.daemon = False

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True

    def fire(self):
        if not self.cancelled:
            self.fn(*self.args)


@pytest.fixture
def setup():
    sent, settled, replies = [], [], {}
    timers = Timers()
    gate = {"on": True}
    arb = Arbiter(send_up=sent.append, gate=lambda: gate["on"],
                  on_settled=lambda key, fp: settled.append((key, fp)), timer=timers)
    return arb, sent, settled, replies, timers, gate


def perm(sid="s", tid="t1", tool="Bash", cmd="rm -rf build", **kw):
    p = {"hook_event_name": "PermissionRequest", "session_id": sid, "cwd": "/w/app",
         "tool_name": tool, "tool_use_id": tid, "tool_input": {"command": cmd}}
    p.update(kw)
    return p


def submit(arb, replies, payload, kind="permission", key=None):
    name = payload.get("tool_use_id") or "x"
    key = key or ae.session_key("local", "claude", payload["session_id"], payload["cwd"])
    return arb.submit(kind, "claude", payload, key, lambda ans, n=name: replies.__setitem__(n, ans))


def fp_of(p):
    return ae.fingerprint(p["session_id"], p.get("tool_use_id"), p["tool_name"], p["tool_input"])


def test_allow_answers_the_waiting_hook(setup):
    arb, sent, settled, replies, _, _ = setup
    p = perm()
    submit(arb, replies, p)
    assert sent[0]["name"] == "agent_pending"
    data = sent[0]["data"]
    assert data["fingerprint"] == fp_of(p) and data["summary"] == "Bash: rm -rf build"
    assert arb.decide(fp_of(p), "allow") is True
    assert replies["t1"] == {"decision": "allow"}
    assert sent[-1]["name"] == "agent_settled" and sent[-1]["data"]["reason"] == "decided"
    assert settled == [(data["key"], fp_of(p))]
    assert arb.pending() == []


def test_stale_fingerprint_ignored(setup):
    arb, _, _, replies, _, _ = setup
    p = perm()
    submit(arb, replies, p)
    other = perm(tid="t2", cmd="ls")
    assert arb.decide(fp_of(other), "allow") is False
    assert "t1" not in replies
    assert arb.decide(fp_of(p), "deny", message="no") is True
    assert replies["t1"] == {"decision": "deny", "message": "no"}
    assert arb.decide(fp_of(p), "allow") is False  # single use


def test_always_carries_the_suggestions(setup):
    arb, _, _, replies, _, _ = setup
    sugg = [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm test"}]}]
    p = perm(permission_suggestions=sugg)
    submit(arb, replies, p)
    arb.decide(fp_of(p), "always")
    assert replies["t1"] == {"decision": "always", "updated_permissions": sugg}


def test_gate_off_answers_ask_at_once(setup):
    arb, sent, _, replies, _, gate = setup
    gate["on"] = False
    submit(arb, replies, perm())
    assert replies["t1"] == {"decision": "ask"}
    assert arb.pending() == [] and sent == []


def test_queue_cap_sends_the_newest_back_to_the_terminal(setup):
    arb, _, _, replies, _, _ = setup
    for i in range(Arbiter.MAX_PENDING):
        submit(arb, replies, perm(tid=f"t{i}", cmd=f"c{i}"))
    submit(arb, replies, perm(tid="t99", cmd="extra"))
    assert replies == {"t99": {"decision": "ask"}}
    assert len(arb.pending()) == Arbiter.MAX_PENDING


def test_timeout_releases_with_ask(setup):
    arb, sent, _, replies, timers, _ = setup
    submit(arb, replies, perm())
    assert timers.made[0].delay == Arbiter.RELEASE_AFTER
    timers.made[0].fire()
    assert replies["t1"] == {"decision": "ask"}
    assert sent[-1]["data"]["reason"] == "timeout"


def test_answered_in_terminal_settles_on_post_tool_use(setup):
    arb, sent, _, replies, timers, _ = setup
    p = perm()
    key = ae.session_key("local", "claude", "s", "/w/app")
    submit(arb, replies, p)
    arb.observe({"hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Bash",
                 "tool_use_id": "t1", "tool_input": {"command": "rm -rf build"}}, key)
    assert arb.pending() == []
    assert sent[-1]["data"]["reason"] == "elsewhere"
    assert timers.made[0].cancelled


def test_post_tool_use_of_another_call_does_not_settle(setup):
    arb, _, _, replies, _, _ = setup
    key = ae.session_key("local", "claude", "s", "/w/app")
    submit(arb, replies, perm())
    arb.observe({"hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Bash",
                 "tool_use_id": "zz", "tool_input": {"command": "ls"}}, key)
    assert len(arb.pending()) == 1


def test_turn_end_settles_everything_of_that_session(setup):
    arb, _, _, replies, _, _ = setup
    key_s = ae.session_key("local", "claude", "s", "/w/app")
    submit(arb, replies, perm(tid="a"))
    submit(arb, replies, perm(sid="other", tid="b"))
    arb.observe({"hook_event_name": "Stop", "session_id": "s", "cwd": "/w/app"}, key_s)
    assert [p["session_id"] for p in arb.pending()] == ["other"]


def test_peer_gone_settles_without_a_reply(setup):
    arb, sent, _, replies, _, _ = setup
    token = submit(arb, replies, perm())
    arb.peer_gone(token)
    assert arb.pending() == [] and "t1" not in replies
    assert sent[-1]["data"]["reason"] == "gone"


def test_question_answers_keep_their_shape(setup):
    arb, sent, _, replies, _, _ = setup
    qs = [{"question": "Which db?", "multiSelect": False, "options": [{"label": "A"}, {"label": "B"}]},
          {"question": "Which tests?", "multiSelect": True,
           "options": [{"label": "unit"}, {"label": "e2e"}]}]
    p = {"hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/w/app",
         "tool_name": "AskUserQuestion", "tool_use_id": "q", "tool_input": {"questions": qs}}
    submit(arb, replies, p, kind="ask")
    assert sent[0]["data"]["questions"] == qs and sent[0]["data"]["kind"] == "ask"
    fp = ae.fingerprint("s", "q", "AskUserQuestion", {"questions": qs})
    assert arb.decide(fp, "answer", answers={"Which db?": ["B"], "Which tests?": ["unit", "e2e"]})
    assert replies["q"] == {"decision": "answer",
                            "answers": {"Which db?": "B", "Which tests?": ["unit", "e2e"]}}


def test_question_cannot_be_allowed_and_approval_cannot_be_answered(setup):
    arb, _, _, replies, _, _ = setup
    p = perm()
    submit(arb, replies, p)
    assert arb.decide(fp_of(p), "answer", answers={}) is False
    assert len(arb.pending()) == 1


def test_pending_lists_public_fields(setup):
    arb, _, _, replies, _, _ = setup
    submit(arb, replies, perm())
    item = arb.pending()[0]
    assert set(item) >= {"fingerprint", "kind", "tool", "summary", "session_id", "cwd", "agent",
                         "key", "at"}
    assert "reply" not in item
