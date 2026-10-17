"""Tests for the WebUI coding HTTP dispatcher (``/api/coding/*``).

These exercise ``handle_coding_request`` — a *pure* dispatcher that takes
(method, path, body, manager) and returns ``(status, dict)`` — against a fake
store holder. Sessions are the Agents layer's (``/agents/*``); what's here is
projects, their sync, the island's ``/projects?expand=sessions`` view, usage,
folder suggestions and Live Activity tokens.
"""
from __future__ import annotations

from api.coding_routes import (
    CODING_PATH_PREFIX,
    handle_coding_request,
    matches,
)


# ── fakes ──────────────────────────────────────────────────────────────────────

class FakeStore:
    def __init__(self):
        self.projects = []
        self.create_calls = []
        self.update_calls = []
        self.deleted_projects = []
        self.detached = []          # (sid,) where project_id was nulled
        self.deleted_sessions = []
        self.sessions = []          # legacy coding_sessions rows
        self.conversations = []     # Agents conversation records
        self.settings = {}
        self.la_tokens = []         # (token, device_id) from upsert_la_token
        self._next = 1

    def upsert_la_token(self, token, device_id=None):
        self.la_tokens.append((token, device_id))

    def create_project(self, *, name, repo_path, host="server", default_branch=None):
        # String id mirroring the real store's "cp_..." convention — path
        # segments arrive as strings, so an int id would never match.
        pid = "cp_%d" % self._next
        self._next += 1
        self.create_calls.append(
            dict(name=name, repo_path=repo_path, host=host,
                 default_branch=default_branch))
        self.projects.append(
            dict(id=pid, name=name, repo_path=repo_path, host=host,
                 default_branch=default_branch))
        return pid

    def list_projects(self):
        return [dict(p) for p in self.projects]

    def get_project(self, pid):
        for p in self.projects:
            if p["id"] == pid:
                return dict(p)
        return None

    def update_project(self, pid, **fields):
        self.update_calls.append((pid, fields))
        for p in self.projects:
            if p["id"] == pid:
                p.update(fields)

    def delete_project(self, pid):
        self.deleted_projects.append(pid)
        self.projects = [p for p in self.projects if p["id"] != pid]

    def list_sessions(self, *, status=None, project_id=None, device_id=None):
        out = list(self.sessions)
        if project_id is not None:
            out = [s for s in out if s.get("project_id") == project_id]
        return out

    def update_session(self, sid, **fields):
        if fields.get("project_id", "x") is None:
            self.detached.append(sid)

    def delete_session(self, sid):
        self.deleted_sessions.append(sid)

    def list_conversations(self, owner=None):
        return [dict(c) for c in self.conversations]

    def get_setting(self, key, default=None):
        return self.settings.get(key, default)

    def set_setting(self, key, value):
        self.settings[key] = value


class FakeManager:
    """The store holder ``default_manager()`` hands out (just ``.store``)."""

    def __init__(self):
        self.store = FakeStore()


def conv(sid, *, status="live", state="working", project_id=None, cwd="/x/app",
         owner="dev-1", agent="claude", last=100.0, title="Fix it"):
    return {"ckey": f"{agent}|{sid}", "agent": agent, "session_id": sid, "status": status,
            "state": state, "project_id": project_id, "cwd": cwd, "owner": owner,
            "last_event_at": last, "title": title}


# ── prefix / matches ────────────────────────────────────────────────────────────

def test_prefix_constant():
    assert CODING_PATH_PREFIX == "/api/coding"


def test_matches_only_under_prefix():
    assert matches("/api/coding/projects") is True
    assert matches("/api/coding") is True
    assert matches("/api/codingX") is True  # startswith, per contract
    assert matches("/api/sessions") is False
    assert matches("/other") is False


# ── /projects ──────────────────────────────────────────────────────────────────

def test_get_projects():
    m = FakeManager()
    m.store.create_project(name="x", repo_path="/r")
    status, body = handle_coding_request("GET", "/projects", None, manager=m)
    assert status == 200
    assert body["projects"] == m.store.list_projects()


def test_post_projects_ok():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/projects",
        {"name": "proj", "repo_path": "/repo", "default_branch": "main"},
        manager=m)
    assert status == 200
    assert body == {"ok": True, "project_id": "cp_1"}
    assert m.store.create_calls == [
        dict(name="proj", repo_path="/repo", host="server", default_branch="main")
    ]


def test_post_projects_missing_name():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/projects", {"repo_path": "/repo"}, manager=m)
    assert status == 400
    assert "error" in body
    assert m.store.create_calls == []


def test_post_projects_missing_repo_path():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/projects", {"name": "proj"}, manager=m)
    assert status == 400
    assert "error" in body


def test_post_projects_default_branch_optional():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/projects", {"name": "p", "repo_path": "/r"}, manager=m)
    assert status == 200
    assert m.store.create_calls[0]["default_branch"] is None


def test_unknown_path_is_404():
    m = FakeManager()
    status, body = handle_coding_request("GET", "/nope", None, manager=m)
    assert status == 404
    assert body == {"error": "not found"}


def test_unknown_method_on_known_path_is_404():
    m = FakeManager()
    status, body = handle_coding_request("DELETE", "/projects", None, manager=m)
    assert status == 404
    assert body == {"error": "not found"}


def test_body_none_treated_as_empty_for_post():
    m = FakeManager()
    status, body = handle_coding_request("POST", "/projects", None, manager=m)
    assert status == 400  # name/repo_path missing, not a crash


def test_get_projects_no_expand_has_no_sessions_key():
    m = FakeManager()
    m.store.create_project(name="p", repo_path="/r")
    status, body = handle_coding_request("GET", "/projects", None, manager=m)
    assert "ungrouped" not in body
    assert "sessions" not in body["projects"][0]


def test_get_projects_expand_groups_conversations_and_ungrouped():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.conversations = [conv("s1", project_id=pid), conv("s2", status="ended")]
    status, body = handle_coding_request("GET", "/projects?expand=sessions", None, manager=m)
    assert status == 200
    assert [s["id"] for s in body["projects"][0]["sessions"]] == ["claude|s1"]
    assert [s["id"] for s in body["ungrouped"]] == ["claude|s2"]
    assert body["ungrouped"][0]["status"] == "stopped"


def test_get_projects_expand_project_with_no_sessions():
    m = FakeManager()
    m.store.create_project(name="empty", repo_path="/r")
    status, body = handle_coding_request("GET", "/projects?expand=sessions", None, manager=m)
    assert status == 200
    assert body["projects"][0]["sessions"] == []
    assert body["ungrouped"] == []


def test_get_projects_live_only_keeps_what_the_island_shows():
    """The iPhone island polls ?expand=sessions&live=1: only live sessions and the
    projects holding them, in the CodingSession shape its LiveFleet reads."""
    m = FakeManager()
    busy = m.store.create_project(name="busy", repo_path="/busy")
    m.store.create_project(name="history", repo_path="/history")
    m.store.conversations = [
        conv("run", project_id=busy, state="approval", last=200.0),
        conv("asleep", project_id=busy, status="asleep"),
        conv("done", project_id=busy, status="ended"),
        conv("loose", state="thinking", cwd="/x/loose", owner="server"),
        conv("chat", agent="jarvis"),
    ]
    status, body = handle_coding_request(
        "GET", "/projects?expand=sessions&live=1", None, manager=m)
    assert status == 200
    assert [p["name"] for p in body["projects"]] == ["busy"]
    run = body["projects"][0]["sessions"]
    assert [s["id"] for s in run] == ["claude|run"]
    s = run[0]
    assert (s["status"], s["activity_state"], s["host"], s["device_id"]) == \
        ("running", "waiting", "desktop", "dev-1")
    assert (s["cwd"], s["project_id"], s["last_activity_at"], s["title"]) == \
        ("/x/app", busy, 200.0, "Fix it")
    assert s["source"] != "discovered-transcript" and s["attached"] == 1
    loose = body["ungrouped"]
    assert [(x["id"], x["activity_state"], x["host"]) for x in loose] == \
        [("claude|loose", "working", "server")]
    assert "ignored" not in body


def test_paused_sessions_are_not_live_for_the_island():
    m = FakeManager()
    m.store.conversations = [conv("a", status="asleep"), conv("b", status="offline")]
    status, body = handle_coding_request("GET", "/projects?expand=sessions", None, manager=m)
    assert [s["status"] for s in body["ungrouped"]] == ["paused", "paused"]
    assert all(s["activity_state"] is None for s in body["ungrouped"])
    status, body = handle_coding_request(
        "GET", "/projects?expand=sessions&live=1", None, manager=m)
    assert body["ungrouped"] == []


def test_the_island_reads_the_trackers_current_state(monkeypatch):
    import agent.coding_la_push as la
    monkeypatch.setattr(la, "_tracked_states", lambda: {("claude", "s1"): "idle"})
    m = FakeManager()
    m.store.conversations = [conv("s1", state="working")]
    _, body = handle_coding_request("GET", "/projects?expand=sessions&live=1", None, manager=m)
    assert body["ungrouped"][0]["activity_state"] == "idle"


def test_a_conversation_whose_project_is_gone_is_ungrouped():
    m = FakeManager()
    m.store.conversations = [conv("s1", project_id="cp_deleted")]
    _, body = handle_coding_request("GET", "/projects?expand=sessions", None, manager=m)
    assert [s["id"] for s in body["ungrouped"]] == ["claude|s1"]


def test_the_old_session_routes_are_gone():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    for method, path in (("GET", "/sessions"), ("POST", "/launch"), ("GET", "/session/x"),
                         ("POST", "/session/x/message"), ("POST", "/session/x/terminal/start"),
                         ("POST", "/activity-event"), ("POST", "/discover/refresh"),
                         ("POST", "/project/" + pid + "/session")):
        status, _ = handle_coding_request(method, path, {"text": "x"}, manager=m)
        assert status == 404, path


# ── POST /project/<id> (update) ─────────────────────────────────────────────────

def test_update_project_sets_fields():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    status, body = handle_coding_request(
        "POST", "/project/" + str(pid),
        {"name": "Renamed", "sync_enabled": False,
         "ignore_rules": "node_modules", "bogus": "ignored"},
        manager=m)
    assert status == 200 and body["ok"] is True
    sent_pid, sent = m.store.update_calls[0]
    assert sent_pid == pid
    # only allow-listed keys pass through; "bogus" is dropped
    assert sent == {"name": "Renamed", "sync_enabled": False,
                    "ignore_rules": "node_modules"}


def test_update_project_unknown_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/project/999", {"name": "x"}, manager=m)
    assert status == 404
    assert m.store.update_calls == []


def test_update_project_empty_id_404():
    m = FakeManager()
    status, body = handle_coding_request("POST", "/project/", {"name": "x"}, manager=m)
    assert status == 404


def _sync_spies(monkeypatch):
    import api.agents_core as ac
    import api.coding_desktop as cd
    started, stopped = [], []
    monkeypatch.setattr(ac, "_start_folder_sync",
                        lambda device, local, server: started.append((device, local, server)))
    monkeypatch.setattr(cd, "stop_folder_sync",
                        lambda device, local, server, **kw: stopped.append((device, local, server)))
    monkeypatch.setenv("JC_CODING_PROJECTS_ROOT", "/srv/cp")
    return started, stopped


def test_turning_a_projects_sync_on_starts_its_folder_sync(monkeypatch):
    started, stopped = _sync_spies(monkeypatch)
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/Users/me/proj")
    status, body = handle_coding_request(
        "POST", "/project/" + pid,
        {"sync_enabled": True, "device_id": "dev-x", "sync_desktop_path": "/Users/me/proj"},
        manager=m)
    assert status == 200 and body["ok"] is True
    assert started == [("dev-x", "/Users/me/proj", "/srv/cp/proj")] and stopped == []


def test_turning_it_off_stops_the_sync_and_is_remembered(monkeypatch):
    """sync_enabled is authoritative: a leftover device/path must not keep it
    alive, and auto-sync never turns a switched-off project back on."""
    from agent.agent_sync_policy import SWITCHED_OFF_SETTING
    started, stopped = _sync_spies(monkeypatch)
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/Users/me/proj")
    m.store.update_project(pid, sync_enabled=1, device_id="dev-x",
                           sync_desktop_path="/Users/me/proj")
    handle_coding_request("POST", "/project/" + pid, {"sync_enabled": False}, manager=m)
    assert stopped == [("dev-x", "/Users/me/proj", "/srv/cp/proj")] and started == []
    assert m.store.settings[SWITCHED_OFF_SETTING] == [pid]
    handle_coding_request("POST", "/project/" + pid, {"sync_enabled": True}, manager=m)
    assert m.store.settings[SWITCHED_OFF_SETTING] == []
    assert started == [("dev-x", "/Users/me/proj", "/srv/cp/proj")]


def test_moving_a_synced_projects_folder_moves_its_sync(monkeypatch):
    started, stopped = _sync_spies(monkeypatch)
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/Users/me/proj")
    m.store.update_project(pid, sync_enabled=1, device_id="dev-x",
                           sync_desktop_path="/Users/me/proj")
    handle_coding_request("POST", "/project/" + pid,
                          {"sync_desktop_path": "/Users/me/proj2"}, manager=m)
    assert stopped == [("dev-x", "/Users/me/proj", "/srv/cp/proj")]
    assert started == [("dev-x", "/Users/me/proj2", "/srv/cp/proj2")]


def test_project_rename_only_does_not_touch_sync(monkeypatch):
    started, stopped = _sync_spies(monkeypatch)
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    handle_coding_request("POST", "/project/" + pid, {"name": "Renamed"}, manager=m)
    assert started == [] and stopped == []


# ── DELETE /project/<id> (soft-ignore by default; ?permanent=1 = hard) ───────────

def test_delete_project_soft_ignores_by_default():
    # Plain DELETE now SOFT-deletes: ignored=1, project + sessions kept (Restore-able).
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.sessions = [
        {"id": "s1", "project_id": pid}, {"id": "s2", "project_id": pid}]
    status, body = handle_coding_request(
        "DELETE", "/project/" + str(pid), None, manager=m)
    assert status == 200 and body.get("ignored") is True
    assert (pid, {"ignored": True}) in m.store.update_calls   # tombstoned
    assert pid not in m.store.deleted_projects                # NOT hard-deleted
    assert m.store.detached == []                             # sessions kept
    assert m.store.deleted_sessions == []


def test_delete_project_permanent_cascade_deletes_sessions():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.sessions = [{"id": "s1", "project_id": pid}]
    status, body = handle_coding_request(
        "DELETE", "/project/" + pid + "?permanent=1&delete_sessions=1", None, manager=m)
    assert status == 200 and body["ok"] is True
    assert m.store.deleted_sessions == ["s1"] and m.store.detached == []
    assert pid in m.store.deleted_projects


def test_delete_project_permanent_detaches_by_default():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.sessions = [{"id": "s1", "project_id": pid}]
    status, body = handle_coding_request(
        "DELETE", "/project/" + str(pid) + "?permanent=1", None, manager=m)
    assert status == 200 and body["ok"] is True
    assert m.store.detached == ["s1"]           # detached, not deleted
    assert pid in m.store.deleted_projects


def test_restore_project_clears_ignored():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    handle_coding_request("DELETE", "/project/" + str(pid), None, manager=m)  # ignore
    status, body = handle_coding_request(
        "POST", "/project/" + str(pid), {"ignored": False}, manager=m)
    assert status == 200 and body["ok"] is True
    assert (pid, {"ignored": False}) in m.store.update_calls


def test_projects_view_buckets_ignored_separately():
    m = FakeManager()
    active = m.store.create_project(name="active", repo_path="/a")
    ign = m.store.create_project(name="ign", repo_path="/b")
    # ignore the second one
    for p in m.store.projects:
        if p["id"] == ign:
            p["ignored"] = 1
    status, body = handle_coding_request(
        "GET", "/projects?expand=sessions", None, manager=m)
    assert status == 200
    assert [p["id"] for p in body["projects"]] == [active]   # active only
    assert [p["id"] for p in body["ignored"]] == [ign]       # ignored bucket


def test_delete_project_unknown_404():
    m = FakeManager()
    status, body = handle_coding_request("DELETE", "/project/999", None, manager=m)
    assert status == 404


def test_project_unknown_action_404():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    status, body = handle_coding_request(
        "GET", "/project/" + str(pid) + "/bogus", None, manager=m)
    assert status == 404


# ── usage, Live Activity tokens, folder suggestions ─────────────────────────────

def test_get_usage_endpoint(monkeypatch):
    import api.coding_routes as cr
    monkeypatch.setattr(cr, "_coding_usage", lambda: {"five_hour_pct": 12, "weekly_pct": 3})
    m = FakeManager()
    status, body = handle_coding_request("GET", "/usage", None, manager=m)
    assert status == 200
    assert body["usage"] == {"five_hour_pct": 12, "weekly_pct": 3}


def test_post_la_token_stores():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/la-token", {"token": "deadbeef", "device_id": "dev1"}, manager=m)
    assert status == 200 and body["ok"] is True
    assert m.store.la_tokens == [("deadbeef", "dev1")]


def test_post_la_token_requires_token():
    m = FakeManager()
    status, body = handle_coding_request("POST", "/la-token", {}, manager=m)
    assert status == 400
    assert m.store.la_tokens == []


def test_dir_suggest_server_lists_local_fs(monkeypatch):
    import agent.coding_dir_suggest as ds
    monkeypatch.setattr(ds, "suggest_dirs",
                        lambda path, **kw: ["/root/a", "/root/b"])
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/dir-suggest?host=server&path=/root/", None, manager=m)
    assert status == 200
    assert body["dirs"] == ["/root/a", "/root/b"] and body["host"] == "server"


def test_dir_suggest_device_uses_bridge(monkeypatch):
    import api.coding_desktop as cd2
    monkeypatch.setattr(cd2, "resolve_desktop_device_id",
                        lambda preferred=None: "dev-1", raising=False)

    class _Bridge:
        def request_dir_list(self, did, *, path, timeout=8.0):
            assert did == "dev-1" and path == "/Users/me/"
            return ["/Users/me/proj"]

    monkeypatch.setattr(cd2, "get_desktop_bridge", lambda: _Bridge(),
                        raising=False)
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/dir-suggest?host=desktop&device_id=dev-1&path=/Users/me/",
        None, manager=m)
    assert status == 200
    assert body["dirs"] == ["/Users/me/proj"] and body["device_id"] == "dev-1"


def test_dir_suggest_device_offline_returns_empty(monkeypatch):
    import api.coding_desktop as cd2

    class _Bridge:
        def request_dir_list(self, did, *, path, timeout=8.0):
            return None  # offline / timed out

    monkeypatch.setattr(cd2, "get_desktop_bridge", lambda: _Bridge(),
                        raising=False)
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/dir-suggest?host=desktop&device_id=dev-9&path=/", None,
        manager=m)
    assert status == 200 and body["dirs"] == [] and "error" in body
