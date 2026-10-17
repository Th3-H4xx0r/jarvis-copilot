import pytest

import agent.coding_la_push as m
from agent.coding_la_push import build_coding_content_state, push_coding_update

_US = "\x1f"


@pytest.fixture(autouse=True)
def _reset_la_push_state():
    """Reset module-level dedupe + rate-limit state before each test so suite
    order can't leak a prior push's signature/timestamp into the next."""
    m._last_sig["v"] = ""
    m._last_push_ts["v"] = 0.0
    yield


_STATE = {"working": "working", "waiting": "approval", "idle": "idle"}


def conv(cid, activity="working", status="live", project_id=None, cwd="/x/a", last=1,
         agent="claude"):
    """An Agents conversation record (agent/agent_conversations.py)."""
    return {"ckey": f"{agent}|{cid}", "agent": agent, "session_id": cid, "status": status,
            "state": _STATE.get(activity, activity), "project_id": project_id, "cwd": cwd,
            "last_event_at": last}


class FakeStore:
    def __init__(self, sessions, projects, tokens):
        self._sessions = sessions
        self._projects = projects
        self._tokens = list(tokens)
        self.deleted = []

    def list_conversations(self):
        return [dict(s) for s in self._sessions]

    def list_projects(self):
        return [dict(p) for p in self._projects]

    def list_la_tokens(self):
        return [dict(t) for t in self._tokens]

    def delete_la_token(self, tok):
        self.deleted.append(tok)
        self._tokens = [t for t in self._tokens if t["token"] != tok]


def test_build_content_state_aggregates_by_project():
    store = FakeStore(
        sessions=[
            conv("s1", project_id="p1", cwd="/x/intel", last=100),
            conv("s2", activity="waiting", project_id="p1", cwd="/x/intel", last=200),
            conv("s3", cwd="/x/jarvis-copilot", last=50),
            conv("s4", status="ended", project_id="p1"),  # not live
        ],
        projects=[{"id": "p1", "name": "IntelliStock"}],
        tokens=[])
    cs = build_coding_content_state(store)
    assert cs["mode"] == "coding"
    assert cs["sessionTotal"] == 3            # s1, s2, s3
    assert cs["entryTotal"] == 2              # IntelliStock + jarvis-copilot
    assert cs["waitingCount"] == 1            # s2
    # IntelliStock aggregates to 'waiting' (s2) → spotlight-sorted first, and
    # carries per-session sub-states (3rd field) since it has 2 live sessions:
    # ordered waiting > working → "p,w".
    assert cs["sessions"][0].split(_US) == ["IntelliStock", "waiting", "p,w"]
    # A single-session row omits the 3rd field (renders as one solid segment).
    assert cs["sessions"][1].split(_US) == ["jarvis-copilot", "working"]
    # ALL Codable keys present (Swift Decodable needs every one) — including the
    # custom-design fields added for Dynamic Island Designs.
    for k in ("state", "transcript", "activity", "connected", "devices", "mode",
              "sessions", "sessionTotal", "entryTotal", "waitingCount",
              "usage5", "usageWeek", "usage5Resets", "usageWeekResets",
              "designId", "designVersion", "data"):
        assert k in cs


def test_per_session_substates_capped_and_ordered():
    # One project with many sessions: the 3rd field lists per-session sub-states
    # ordered waiting>working>idle and capped at 8.
    sessions = []
    for i in range(10):
        sessions.append(conv(f"s{i}", activity="idle", project_id="p1", cwd="/x/big", last=i))
    sessions[0]["state"] = "working"
    sessions[1]["state"] = "approval"
    store = FakeStore(sessions, [{"id": "p1", "name": "Big"}], [])
    cs = build_coding_content_state(store)
    parts = cs["sessions"][0].split(_US)
    assert parts[0] == "Big" and parts[1] == "waiting"
    subs = parts[2].split(",")
    assert len(subs) == 8                 # capped from 10
    assert subs[0] == "p" and subs[1] == "w"   # waiting, then working, then idle
    assert all(s in ("w", "p", "i") for s in subs)


def test_single_session_project_has_no_substate_field():
    store = FakeStore(
        [conv("s1", project_id="p1", cwd="/x/solo")],
        [{"id": "p1", "name": "Solo"}], [])
    cs = build_coding_content_state(store)
    assert cs["sessions"][0].split(_US) == ["Solo", "working"]


def test_build_content_state_none_when_no_live():
    assert build_coding_content_state(FakeStore([], [], [])) is None
    # an ended conversation is not live
    store = FakeStore([conv("t", status="ended")], [], [])
    assert build_coding_content_state(store) is None


def test_build_content_state_usage():
    store = FakeStore([conv("s")], [], [])
    cs = build_coding_content_state(store, usage={
        "five_hour_pct": 47, "weekly_pct": 23,
        "five_hour_resets": "2h 10m", "weekly_resets": "Mon"})
    assert cs["usage5"] == 47 and cs["usageWeek"] == 23
    assert cs["usage5Resets"] == "2h 10m" and cs["usageWeekResets"] == "Mon"


def test_push_dedupes_and_sends():
    m._last_sig["v"] = ""  # reset module dedupe
    store = FakeStore(
        [conv("s")],
        [], [{"token": "tokA"}])
    sent = []

    def fake(tok, cs, event="update"):
        sent.append((tok, cs["mode"]))
        return {"ok": True}

    assert push_coding_update(store, sender=fake) == 1
    assert sent == [("tokA", "coding")]
    # unchanged content → deduped, no second send
    assert push_coding_update(store, sender=fake) == 0
    assert len(sent) == 1


def test_paused_sessions_and_jarvis_chats_are_not_live():
    """Asleep / offline Mac sessions read as paused: off the island. Jarvis's own
    chats aren't coding sessions."""
    store = FakeStore(
        sessions=[conv("a", status="asleep"), conv("b", status="offline"),
                  conv("c", status="moving"), conv("j", agent="jarvis"),
                  conv("live", activity="waiting", cwd="/x/app")],
        projects=[], tokens=[])
    cs = build_coding_content_state(store)
    assert cs["sessionTotal"] == 1 and cs["waitingCount"] == 1
    assert cs["sessions"] == ["app" + _US + "waiting"]


def test_question_counts_as_waiting_and_thinking_as_working():
    store = FakeStore([conv("q", activity="question", project_id="p1", cwd="/x/p", last=2),
                       conv("t", activity="thinking", project_id="p1", cwd="/x/p", last=1)],
                      [{"id": "p1", "name": "P"}], [])
    cs = build_coding_content_state(store)
    assert cs["waitingCount"] == 1
    assert cs["sessions"][0].split(_US) == ["P", "waiting", "p,w"]


def test_the_trackers_current_state_wins_over_the_stored_one(monkeypatch):
    """Between hooks the stored state can lag (the tracker's sweep moves it on)."""
    monkeypatch.setattr(m, "_tracked_states", lambda: {("claude", "s"): "idle"})
    cs = build_coding_content_state(FakeStore([conv("s", activity="working", cwd="/x/w")],
                                              [], []))
    assert cs["sessions"] == ["w" + _US + "idle"]


def test_push_clears_fleet_on_live_to_empty_edge():
    # When the LAST live coding session disappears (e.g. its Mac went to
    # sleep), build_coding_content_state returns None. Returning 0 here used to
    # mean "no push" → a SUSPENDED device's Dynamic Island froze on the now-dead
    # fleet (the native LiveActivityManager.update never auto-ends). The server
    # must push ONE resting/clear state on the live->empty edge.
    m._last_sig["v"] = ""
    m._last_push_ts["v"] = 0.0
    sessions = [conv("s")]
    store = FakeStore(sessions, [], [{"token": "tokA"}])
    sent = []

    def fake(tok, cs, event="update"):
        sent.append((tok, cs["mode"], cs["sessionTotal"]))
        return {"ok": True}

    assert push_coding_update(store, sender=fake) == 1
    assert sent[-1] == ("tokA", "coding", 1)
    # the only session vanishes → fleet empty
    sessions.clear()
    m._last_push_ts["v"] = 0.0  # bypass the 15s rate-limit for the test
    assert push_coding_update(store, sender=fake) == 1   # a CLEAR push went out
    assert sent[-1][0] == "tokA"
    assert sent[-1][2] == 0                                # sessionTotal 0 → cleared
    # still empty → idempotent, no repeat clear push
    m._last_push_ts["v"] = 0.0
    assert push_coding_update(store, sender=fake) == 0


def test_push_silent_when_never_had_live_content():
    # Cold start with no live coding sessions: stay silent (don't push a resting
    # state that could stomp a voice turn the client owns over the same activity).
    m._last_sig["v"] = ""
    m._last_push_ts["v"] = 0.0
    store = FakeStore([], [], [{"token": "tokA"}])
    sent = []

    def fake(tok, cs, event="update"):
        sent.append(tok)
        return {"ok": True}

    assert push_coding_update(store, sender=fake) == 0
    assert sent == []


def test_push_drops_unregistered_token():
    m._last_sig["v"] = ""
    store = FakeStore(
        [conv("s")],
        [], [{"token": "bad"}])

    def fake(tok, cs, event="update"):
        return {"ok": False, "status": 410, "error": "Unregistered"}

    assert push_coding_update(store, sender=fake) == 0
    assert "bad" in store.deleted


def _one_live_store():
    return FakeStore(sessions=[conv("s1", activity="waiting", cwd="/x/app", last=100)],
                     projects=[], tokens=[])


def test_lead_session_from_the_hook_tracker(monkeypatch):
    monkeypatch.setattr(m, "_lead_summary", lambda: {
        "agent": "claude", "project": "app", "state": "approval", "step": "Bash: rm -rf build " * 10,
        "fingerprint": "fp1", "kind": "approval", "since": 1781000000.0, "key": "d1|claude|s1"})
    cs = build_coding_content_state(_one_live_store())
    assert cs["leadAgent"] == "Claude Code" and cs["leadProject"] == "app"
    assert cs["leadState"] == "approval" and cs["leadKind"] == "approval"
    assert cs["leadFingerprint"] == "fp1" and cs["leadKey"] == "d1|claude|s1"
    assert len(cs["leadStep"]) <= 60 and cs["leadSince"] == 1781000000.0


def test_lead_keys_are_always_sent(monkeypatch):
    monkeypatch.setattr(m, "_lead_summary", lambda: None)
    cs = build_coding_content_state(_one_live_store())
    for key in ("leadAgent", "leadProject", "leadState", "leadStep", "leadFingerprint",
                "leadKind", "leadKey"):
        assert cs[key] == ""
    assert cs["leadSince"] == 0


def test_a_new_step_alone_does_not_push_again(monkeypatch):
    """The Live Activity follows state changes only: a session working through
    tool calls must not push on every step (battery, APNs budget)."""
    lead = {"agent": "claude", "project": "app", "state": "working", "step": "Bash: one",
            "fingerprint": "", "kind": "", "since": 1.0, "key": "k"}
    monkeypatch.setattr(m, "_lead_summary", lambda: dict(lead))
    store = FakeStore(sessions=[conv("s1", cwd="/x/app", last=100)],
                      projects=[], tokens=[{"token": "t1"}])
    sent = []
    sender = lambda token, cs, **kw: sent.append(cs) or {"ok": True}  # noqa: E731
    assert push_coding_update(store, force=True, sender=sender) == 1
    lead["step"] = "Bash: two"
    m._last_push_ts["v"] = 0.0
    assert push_coding_update(store, sender=sender) == 0
    lead["state"] = "approval"
    m._last_push_ts["v"] = 0.0
    assert push_coding_update(store, sender=sender) == 1


class SettingsStore(FakeStore):
    """A store with the Code Master settings document (the real one has it)."""

    def __init__(self, *a, settings=None, **kw):
        super().__init__(*a, **kw)
        self._settings = {"notifications": settings} if settings is not None else {}

    def get_setting(self, key, default=None):
        return self._settings.get(key, default)


def _live_rows():
    return [conv("s")]


def test_the_jarvis_activity_leaves_coding_to_the_agent_activities():
    """With per-agent activities on (the default), the shared Jarvis activity no
    longer carries the coding fleet — it stays the voice / custom island."""
    sent = []
    store = SettingsStore(_live_rows(), [], [{"token": "tokA"}])
    assert push_coding_update(store, sender=lambda t, cs, event="update": sent.append(cs) or {"ok": True}) == 0
    assert sent == []


def test_turning_agent_activities_off_puts_coding_back_on_the_jarvis_activity():
    sent = []
    store = SettingsStore(_live_rows(), [], [{"token": "tokA"}],
                          settings={"agent_live": {"enabled": False}})
    assert push_coding_update(store, sender=lambda t, cs, event="update": sent.append(cs) or {"ok": True}) == 1
    assert sent[-1]["mode"] == "coding"


def test_turning_agent_activities_on_clears_a_coding_fleet_already_shown():
    sent = []
    fake = lambda t, cs, event="update": sent.append(cs) or {"ok": True}  # noqa: E731
    store = SettingsStore(_live_rows(), [], [{"token": "tokA"}],
                          settings={"agent_live": {"enabled": False}})
    assert push_coding_update(store, sender=fake) == 1
    store._settings["notifications"] = {"agent_live": {"enabled": True}}
    m._last_push_ts["v"] = 0.0
    assert push_coding_update(store, sender=fake) == 1      # the resting state, once
    assert sent[-1]["mode"] == "voice" and sent[-1]["sessionTotal"] == 0
