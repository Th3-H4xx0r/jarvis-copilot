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


class FakeStore:
    def __init__(self, sessions, projects, tokens):
        self._sessions = sessions
        self._projects = projects
        self._tokens = list(tokens)
        self.deleted = []

    def list_sessions(self):
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
            {"id": "s1", "status": "running", "activity_state": "working",
             "project_id": "p1", "cwd": "/x/intel", "last_activity_at": 100},
            {"id": "s2", "status": "running", "activity_state": "waiting",
             "project_id": "p1", "cwd": "/x/intel", "last_activity_at": 200},
            {"id": "s3", "status": "running", "activity_state": "working",
             "project_id": None, "cwd": "/x/jarvis-copilot", "last_activity_at": 50},
            {"id": "s4", "status": "stopped", "project_id": "p1"},  # not live
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
    # ALL Codable keys present (Swift Decodable needs every one).
    for k in ("state", "transcript", "activity", "connected", "devices", "mode",
              "sessions", "sessionTotal", "entryTotal", "waitingCount",
              "usage5", "usageWeek", "usage5Resets", "usageWeekResets"):
        assert k in cs


def test_per_session_substates_capped_and_ordered():
    # One project with many sessions: the 3rd field lists per-session sub-states
    # ordered waiting>working>idle and capped at 8.
    sessions = []
    for i in range(10):
        sessions.append({"id": f"s{i}", "status": "running",
                         "activity_state": "idle", "project_id": "p1",
                         "cwd": "/x/big", "last_activity_at": i})
    sessions[0]["activity_state"] = "working"
    sessions[1]["activity_state"] = "waiting"
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
        [{"id": "s1", "status": "running", "activity_state": "working",
          "project_id": "p1", "cwd": "/x/solo", "last_activity_at": 1}],
        [{"id": "p1", "name": "Solo"}], [])
    cs = build_coding_content_state(store)
    assert cs["sessions"][0].split(_US) == ["Solo", "working"]


def test_build_content_state_none_when_no_live():
    assert build_coding_content_state(FakeStore([], [], [])) is None
    # a discovered-transcript idle row is not "live"
    store = FakeStore([{"id": "t", "status": "idle", "source": "discovered-transcript",
                        "project_id": None, "cwd": "/x/a"}], [], [])
    assert build_coding_content_state(store) is None


def test_build_content_state_usage():
    store = FakeStore([{"id": "s", "status": "running", "activity_state": "working",
                        "project_id": None, "cwd": "/x/a"}], [], [])
    cs = build_coding_content_state(store, usage={
        "five_hour_pct": 47, "weekly_pct": 23,
        "five_hour_resets": "2h 10m", "weekly_resets": "Mon"})
    assert cs["usage5"] == 47 and cs["usageWeek"] == 23
    assert cs["usage5Resets"] == "2h 10m" and cs["usageWeekResets"] == "Mon"


def test_push_dedupes_and_sends():
    m._last_sig["v"] = ""  # reset module dedupe
    store = FakeStore(
        [{"id": "s", "status": "running", "activity_state": "working",
          "project_id": None, "cwd": "/x/a", "last_activity_at": 1}],
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


def test_dim_forgotten_detached_idle_session():
    # A discovered-tmux session that's idle with NO client attached is "forgotten"
    # → encoded 'dim' (dimmed + sorted last) but still COUNTED (de-emphasize, not
    # hide). Alongside an attached working session in the same project, the project
    # aggregates to the active state and the dim one shows as a 'd' sub-segment.
    store = FakeStore(
        sessions=[
            {"id": "a", "status": "running", "activity_state": "working",
             "source": "discovered-tmux", "attached": 1,
             "project_id": "p1", "cwd": "/x/proj", "last_activity_at": 2},
            {"id": "b", "status": "running", "activity_state": "idle",
             "source": "discovered-tmux", "attached": 0,
             "project_id": "p1", "cwd": "/x/proj", "last_activity_at": 1},
        ],
        projects=[{"id": "p1", "name": "Proj"}], tokens=[])
    cs = build_coding_content_state(store)
    assert cs["sessionTotal"] == 2                  # dim still counts
    parts = cs["sessions"][0].split(_US)
    assert parts[:2] == ["Proj", "working"]
    assert parts[2] == "w,d"                          # working, then dim (sorted last)


def test_all_dim_project_aggregates_to_dim_and_sorts_last():
    store = FakeStore(
        sessions=[
            {"id": "act", "status": "running", "activity_state": "working",
             "source": "discovered-tmux", "attached": 1,
             "project_id": "p1", "cwd": "/x/a", "last_activity_at": 5},
            {"id": "forgot", "status": "running", "activity_state": "idle",
             "source": "discovered-tmux", "attached": 0,
             "project_id": "p2", "cwd": "/x/b", "last_activity_at": 9},
        ],
        projects=[{"id": "p1", "name": "Active"}, {"id": "p2", "name": "Forgotten"}],
        tokens=[])
    cs = build_coding_content_state(store)
    # The all-dim project aggregates to 'dim' and sorts AFTER the active one even
    # though it's more recent.
    states = [s.split(_US)[1] for s in cs["sessions"]]
    assert states == ["working", "dim"]
    assert cs["sessions"][0].split(_US)[0] == "Active"
    assert cs["sessions"][1].split(_US)[0] == "Forgotten"


def test_attached_idle_is_not_dim():
    # An ATTACHED idle session (the one you're looking at) is normal idle, never dim.
    store = FakeStore(
        [{"id": "s", "status": "running", "activity_state": "idle",
          "source": "discovered-tmux", "attached": 1,
          "project_id": None, "cwd": "/x/here", "last_activity_at": 1}], [], [])
    cs = build_coding_content_state(store)
    assert cs["sessions"][0].split(_US)[1] == "idle"


def test_push_clears_fleet_on_live_to_empty_edge():
    # When the LAST live coding session disappears (e.g. reaped because its Mac
    # went away), build_coding_content_state returns None. Returning 0 here used to
    # mean "no push" → a SUSPENDED device's Dynamic Island froze on the now-dead
    # fleet (the native LiveActivityManager.update never auto-ends). The server
    # must push ONE resting/clear state on the live->empty edge.
    m._last_sig["v"] = ""
    m._last_push_ts["v"] = 0.0
    sessions = [{"id": "s", "status": "running", "activity_state": "working",
                 "project_id": None, "cwd": "/x/a", "last_activity_at": 1}]
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
        [{"id": "s", "status": "running", "activity_state": "working",
          "project_id": None, "cwd": "/x/a"}],
        [], [{"token": "bad"}])

    def fake(tok, cs, event="update"):
        return {"ok": False, "status": 410, "error": "Unregistered"}

    assert push_coding_update(store, sender=fake) == 0
    assert "bad" in store.deleted
