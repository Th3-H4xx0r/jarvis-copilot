import agent.coding_la_push as m
from agent.coding_la_push import build_coding_content_state, push_coding_update

_US = "\x1f"


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
    # IntelliStock aggregates to 'waiting' (s2) → spotlight-sorted first.
    assert cs["sessions"][0].split(_US) == ["IntelliStock", "waiting"]
    assert cs["sessions"][1].split(_US) == ["jarvis-copilot", "working"]
    # ALL Codable keys present (Swift Decodable needs every one).
    for k in ("state", "transcript", "activity", "connected", "devices", "mode",
              "sessions", "sessionTotal", "entryTotal", "waitingCount",
              "usage5", "usageWeek", "usage5Resets", "usageWeekResets"):
        assert k in cs


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
