"""Approvals and questions through the server: a Mac's waiting hook is announced
(agent_pending), the phone decides through the existing /permission endpoints,
and the decision goes back to exactly that Mac and that request."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import pytest  # noqa: E402

from api import agent_hooks  # noqa: E402
from api import coding_permission as cp  # noqa: E402
from api.coding_routes import handle_coding_request  # noqa: E402


class FakeStore:
    def __init__(self):
        self.settings = {"notifications": {"remote_approvals": True}}

    def get_setting(self, key, default=None):
        return self.settings.get(key, default)

    def set_setting(self, key, value):
        self.settings[key] = value

    def list_sessions(self, **kw):
        return []


class FakeManager:
    def __init__(self):
        self.store = FakeStore()


@pytest.fixture(autouse=True)
def env(monkeypatch):
    cp._reset_for_tests()
    frames, pushes = [], []
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "send_frame",
                        lambda device_id, frame: frames.append((device_id, frame)) or True)
    monkeypatch.setattr(device_bridge, "connected_device_ids", lambda: ["d1", "d2"])
    monkeypatch.setattr(agent_hooks, "_push_agent_alert",
                        lambda **kw: pushes.append(kw) or 1)
    store = FakeStore()
    monkeypatch.setattr(agent_hooks, "_store", lambda: store)
    yield frames, pushes, store
    cp._reset_for_tests()


PENDING = {"fingerprint": "fp1", "kind": "permission", "agent": "claude",
           "key": "d1|claude|s", "session_id": "s", "cwd": "/Users/p/app", "tool": "Bash",
           "summary": "Bash: rm -rf build", "command": "rm -rf build", "at": 1.0,
           "can_always": True}


def test_pending_from_a_mac_is_listed_and_pushed(env):
    frames, pushes, _ = env
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    items = cp.list_pending()
    assert len(items) == 1
    it = items[0]
    assert (it["fingerprint"], it["kind"], it["device_id"], it["can_always"]) == ("fp1", "permission", "d1", True)
    assert it["summary"] == "Bash: rm -rf build" and it["project"] == "app"
    assert pushes[0]["category"] == "PERMISSION_APPROVAL"
    assert pushes[0]["data"]["request_id"] == it["request_id"]
    assert pushes[0]["data"]["agent_key"] == "d1|claude|s"  # the tap opens that session


def test_the_same_request_announced_twice_is_one_card(env):
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    assert len(cp.list_pending()) == 1


def test_phone_verdict_goes_back_to_that_mac(env):
    frames, _, _ = env
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    rid = cp.list_pending()[0]["request_id"]
    status, body = handle_coding_request("POST", "/permission/verdict",
                                         {"request_id": rid, "decision": "allow"},
                                         manager=FakeManager())
    assert status == 200 and body["ok"] is True
    assert frames == [("d1", {"type": "agent_decision", "fingerprint": "fp1",
                              "decision": "allow", "message": "", "answers": None})]
    assert cp.list_pending() == []


def test_always_and_deny_message_pass_through(env):
    frames, _, _ = env
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    rid = cp.list_pending()[0]["request_id"]
    handle_coding_request("POST", "/permission/verdict",
                          {"request_id": rid, "decision": "always"}, manager=FakeManager())
    assert frames[-1][1]["decision"] == "always"
    agent_hooks.on_agent_pending("d1", dict(PENDING, fingerprint="fp2"))
    rid = cp.list_pending()[0]["request_id"]
    handle_coding_request("POST", "/permission/verdict",
                          {"request_id": rid, "decision": "deny", "message": "use make"},
                          manager=FakeManager())
    assert frames[-1][1] == {"type": "agent_decision", "fingerprint": "fp2", "decision": "deny",
                             "message": "use make", "answers": None}


def test_question_is_pushed_and_answered(env):
    frames, pushes, _ = env
    q = [{"question": "Which db?", "multiSelect": False, "options": [{"label": "A"}, {"label": "B"}]}]
    agent_hooks.on_agent_pending("d1", dict(PENDING, kind="ask", fingerprint="fq",
                                            tool="AskUserQuestion", questions=q))
    it = cp.list_pending()[0]
    assert it["kind"] == "ask" and it["questions"] == q
    assert pushes[0]["category"] == "AGENT_QUESTION"
    status, body = handle_coding_request("POST", "/permission/verdict",
                                         {"request_id": it["request_id"], "decision": "answer",
                                          "answers": {"Which db?": "B"}}, manager=FakeManager())
    assert body["ok"] is True
    assert frames[-1][1]["answers"] == {"Which db?": "B"}
    assert frames[-1][1]["decision"] == "answer"


def test_a_question_cannot_be_allowed(env):
    agent_hooks.on_agent_pending("d1", dict(PENDING, kind="ask", fingerprint="fq", questions=[]))
    rid = cp.list_pending()[0]["request_id"]
    _, body = handle_coding_request("POST", "/permission/verdict",
                                    {"request_id": rid, "decision": "allow"}, manager=FakeManager())
    assert body["ok"] is False


def test_settled_on_the_mac_removes_the_card(env):
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    agent_hooks.on_agent_settled("d1", {"fingerprint": "fp1", "reason": "elsewhere"})
    assert cp.list_pending() == []


def test_settled_from_another_device_is_ignored(env):
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    agent_hooks.on_agent_settled("d2", {"fingerprint": "fp1", "reason": "elsewhere"})
    assert len(cp.list_pending()) == 1


def test_hello_answers_with_the_config(env):
    frames, _, store = env
    agent_hooks.on_agent_hello("d1", {"v": 1})
    assert frames == [("d1", {"type": "agent_config", "remote_approvals": True,
                              "remote_instructions": False})]


def test_settings_change_is_broadcast(env):
    frames, _, _ = env
    m = FakeManager()
    handle_coding_request("POST", "/settings", {"remote_approvals": False}, manager=m)
    sent = {d: f for d, f in frames if f.get("type") == "agent_config"}
    off = {"type": "agent_config", "remote_approvals": False, "remote_instructions": False}
    assert sent == {"d1": off, "d2": off}


def test_server_local_request_goes_to_the_local_arbiter(env, monkeypatch):
    calls = []

    class Arb:
        def decide(self, fp, decision, message=None, answers=None):
            calls.append((fp, decision))
            return True

    monkeypatch.setattr(agent_hooks, "_local_arbiter", lambda: Arb())
    agent_hooks.on_agent_pending(None, dict(PENDING, fingerprint="fl"))
    rid = cp.list_pending()[0]["request_id"]
    handle_coding_request("POST", "/permission/verdict", {"request_id": rid, "decision": "deny"},
                          manager=FakeManager())
    assert calls == [("fl", "deny")]


def test_legacy_poll_flow_still_works(env):
    rid = cp.create_request(tool="Bash", summary="Bash: ls", session_id="", cwd="/w")
    assert cp.resolve(rid, decision="allow") is True
    assert cp.poll(rid)["decision"] == "allow"


# ── the glasses hear about questions and approvals too ──────────────────────

def _glasses(monkeypatch, store, on=True):
    from api import device_bridge
    from api import coding_routes as cr
    monkeypatch.setattr(device_bridge, "all_device_notification_channels",
                        lambda: [{"key": "glasses", "label": "Glasses", "default_on": False}])
    store.settings["notifications"]["events"] = {"needs_input": {"glasses": on, "mobile": True}}
    cards = []
    monkeypatch.setattr(cr, "_send_coding_device_notify",
                        lambda ch, t, b, app="", banner=True: cards.append((ch, t, b, banner)) or True)
    return cards


def test_a_question_reaches_the_glasses_when_the_phone_answers_it(env, monkeypatch):
    """Phone approvals on: the tracker leaves "needs you" to the phone's actionable
    banner, which never reached the glasses. They get the same words, wake-only."""
    _, pushes, store = env
    cards = _glasses(monkeypatch, store)
    agent_hooks.on_agent_pending("d1", dict(PENDING, kind="ask", fingerprint="fq",
                                            questions=[{"question": "Which database?"}]))
    assert cards == [("glasses", "Claude has a question", "app: Which database?", False)]
    assert pushes[0]["title"] == "Claude has a question"


def test_an_approval_reaches_the_glasses(env, monkeypatch):
    _, _, store = env
    cards = _glasses(monkeypatch, store)
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    assert cards == [("glasses", "Claude needs approval", "app: Bash: rm -rf build", False)]


def test_no_glasses_card_when_glasses_are_off_or_the_tracker_sends_it(env, monkeypatch):
    _, _, store = env
    cards = _glasses(monkeypatch, store, on=False)
    agent_hooks.on_agent_pending("d1", dict(PENDING))
    assert cards == []
    cards = _glasses(monkeypatch, store, on=True)
    store.settings["notifications"]["remote_approvals"] = False   # the tracker fans "needs you" out itself
    agent_hooks.on_agent_pending("d1", dict(PENDING, fingerprint="fp9"))
    assert cards == []
