"""Tests for the WebUI Coding Sessions HTTP dispatcher.

These exercise ``handle_coding_request`` — a *pure* dispatcher that takes
(method, path, body, manager) and returns ``(status, dict)`` — against a
FakeManager so no real claude/tmux/git is ever touched. Every contract row
(incl. the 400/404/500 branches and the worktree branch) is covered.
"""
from __future__ import annotations

import pytest

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
        self.sessions = []          # rows used by list_sessions/update_session
        self._next = 1

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
        return list(self.projects)

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
        for s in self.sessions:
            if s["id"] == sid:
                s.update(fields)


class FakeManager:
    """Records calls; ``status`` returns a dict for known ids else None."""

    KNOWN = "sess-known"

    def __init__(self, *, raise_on=None, exc=None):
        self.store = FakeStore()
        self.calls = []
        # When ``raise_on`` matches a method name, raise ``exc`` from it.
        self.raise_on = raise_on
        self.exc = exc or RuntimeError("boom")
        self._sessions = [
            {"id": self.KNOWN, "status": "running", "title": "demo"},
            {"id": "sess-stopped", "status": "stopped", "title": "old"},
        ]

    def _maybe_raise(self, name):
        if self.raise_on == name:
            raise self.exc

    def launch(self, *, cwd, title, initial_prompt, model,
               worktree=False, repo_path=None, skip_permissions=False, sync=None,
               project_id=None):
        self.calls.append(
            ("launch", dict(cwd=cwd, title=title, initial_prompt=initial_prompt,
                            model=model, worktree=worktree, repo_path=repo_path,
                            skip_permissions=skip_permissions, sync=sync,
                            project_id=project_id)))
        self._maybe_raise("launch")
        return {"id": "sess-new", "status": "running", "cwd": cwd,
                "title": title, "project_id": project_id}

    def send_message(self, sid, text):
        self.calls.append(("send_message", sid, text))
        self._maybe_raise("send_message")
        if self.status(sid) is None:
            raise KeyError(sid)

    def status(self, sid):
        self.calls.append(("status", sid))
        self._maybe_raise("status")
        for s in self._sessions:
            if s["id"] == sid:
                return dict(s)
        return None

    def list(self, status=None):
        self.calls.append(("list", status))
        self._maybe_raise("list")
        if status:
            return [dict(s) for s in self._sessions if s["status"] == status]
        return [dict(s) for s in self._sessions]

    def stop(self, sid):
        self.calls.append(("stop", sid))
        self._maybe_raise("stop")
        if self.status(sid) is None:
            raise KeyError(sid)

    def subagents(self, sid):
        self.calls.append(("subagents", sid))
        self._maybe_raise("subagents")
        return [{"name": "tester"}]

    def restart(self, sid):
        self.calls.append(("restart", sid))
        self._maybe_raise("restart")
        return {"id": sid, "status": "running"}

    def delete(self, sid):
        self.calls.append(("delete", sid))
        self._maybe_raise("delete")

    def update_settings(self, sid, **kw):
        self.calls.append(("update_settings", sid, kw))
        self._maybe_raise("update_settings")
        return {"id": sid, "skip_permissions": 1 if kw.get("skip_permissions") else 0}


# ── prefix / matches ────────────────────────────────────────────────────────────

def test_prefix_constant():
    assert CODING_PATH_PREFIX == "/api/coding"


def test_matches_only_under_prefix():
    assert matches("/api/coding/projects") is True
    assert matches("/api/coding") is True
    assert matches("/api/codingX") is True  # startswith, per contract
    assert matches("/api/sessions") is False
    assert matches("/other") is False


# ── GET /projects ───────────────────────────────────────────────────────────────

def test_get_projects():
    m = FakeManager()
    m.store.create_project(name="x", repo_path="/r")
    status, body = handle_coding_request("GET", "/projects", None, manager=m)
    assert status == 200
    assert body["projects"] == m.store.list_projects()


# ── POST /projects ──────────────────────────────────────────────────────────────

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


# ── GET /sessions ───────────────────────────────────────────────────────────────

def test_get_sessions_all():
    m = FakeManager()
    status, body = handle_coding_request("GET", "/sessions", None, manager=m)
    assert status == 200
    assert len(body["sessions"]) == 2
    assert ("list", None) in m.calls


def test_get_sessions_filtered_by_status():
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/sessions?status=running", None, manager=m)
    assert status == 200
    assert [s["id"] for s in body["sessions"]] == [FakeManager.KNOWN]
    assert ("list", "running") in m.calls


# ── POST /launch ────────────────────────────────────────────────────────────────

def test_launch_ok_maps_prompt_to_initial_prompt():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/launch",
        {"cwd": "/work", "title": "t", "prompt": "do it", "model": "opus"},
        manager=m)
    assert status == 200
    assert body["ok"] is True
    assert body["session"]["id"] == "sess-new"
    name, kw = m.calls[0]
    assert name == "launch"
    assert kw["cwd"] == "/work"
    assert kw["initial_prompt"] == "do it"
    assert kw["model"] == "opus"
    assert kw["worktree"] is False


def test_launch_missing_cwd_when_not_worktree():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/launch", {"title": "t"}, manager=m)
    assert status == 400
    assert "error" in body
    assert m.calls == []  # never reached the manager


def test_launch_worktree_requires_repo_path():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/launch", {"worktree": True, "title": "t"}, manager=m)
    assert status == 400
    assert "error" in body
    assert m.calls == []


def test_launch_worktree_ok_without_cwd():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/launch",
        {"worktree": True, "repo_path": "/repo", "title": "t", "prompt": "go"},
        manager=m)
    assert status == 200
    assert body["ok"] is True
    name, kw = m.calls[0]
    assert kw["worktree"] is True
    assert kw["repo_path"] == "/repo"
    assert kw["initial_prompt"] == "go"


def test_launch_manager_exception_is_500():
    m = FakeManager(raise_on="launch", exc=RuntimeError("kaboom"))
    status, body = handle_coding_request(
        "POST", "/launch", {"cwd": "/work"}, manager=m)
    assert status == 500
    assert body["error"] == "kaboom"


# ── GET /session/<id> ───────────────────────────────────────────────────────────

def test_get_session_known():
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/session/" + FakeManager.KNOWN, None, manager=m)
    assert status == 200
    assert body["ok"] is True
    assert body["session"]["id"] == FakeManager.KNOWN
    assert body["subagents"] == [{"name": "tester"}]


def test_get_session_unknown_is_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/session/nope", None, manager=m)
    assert status == 404
    assert "error" in body


# ── POST /session/<id>/message ──────────────────────────────────────────────────

def test_post_message_ok():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/message",
        {"text": "hello"}, manager=m)
    assert status == 200
    assert body == {"ok": True}
    assert ("send_message", FakeManager.KNOWN, "hello") in m.calls


def test_post_message_missing_text():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/message", {}, manager=m)
    assert status == 400
    assert "error" in body
    assert not any(c[0] == "send_message" for c in m.calls)


def test_post_message_unknown_session_is_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/nope/message", {"text": "hi"}, manager=m)
    assert status == 404
    assert "error" in body


def test_post_message_keyerror_from_manager_is_404():
    m = FakeManager(raise_on="send_message", exc=KeyError("nope"))
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/message",
        {"text": "hi"}, manager=m)
    assert status == 404
    assert "error" in body


# ── POST /session/<id>/stop ─────────────────────────────────────────────────────

def test_post_stop_ok():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/stop", None, manager=m)
    assert status == 200
    assert body == {"ok": True}
    assert ("stop", FakeManager.KNOWN) in m.calls


def test_post_stop_unknown_is_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/nope/stop", None, manager=m)
    assert status == 404
    assert "error" in body


def test_stop_generic_exception_is_500():
    m = FakeManager(raise_on="stop", exc=RuntimeError("dead"))
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/stop", None, manager=m)
    assert status == 500
    assert body["error"] == "dead"


# ── unknown routing ─────────────────────────────────────────────────────────────

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


def test_session_id_with_query_string_is_parsed():
    m = FakeManager()
    status, body = handle_coding_request(
        "GET", "/session/" + FakeManager.KNOWN + "?foo=bar", None, manager=m)
    assert status == 200
    assert body["session"]["id"] == FakeManager.KNOWN


def test_body_none_treated_as_empty_for_post():
    m = FakeManager()
    status, body = handle_coding_request("POST", "/projects", None, manager=m)
    assert status == 400  # name/repo_path missing, not a crash


def test_launch_selects_manager_for_host():
    server = FakeManager()
    desktop = FakeManager()
    picked = {}

    def manager_for_host(h):
        picked["h"] = h
        return desktop if h == "desktop" else server

    status, body = handle_coding_request(
        "POST", "/launch",
        {"cwd": "/x", "prompt": "go", "host": "desktop"},
        manager=server, manager_for_host=manager_for_host)
    assert status == 200
    assert picked["h"] == "desktop"
    # the desktop manager launched, not the default server one
    assert any(c[0] == "launch" for c in desktop.calls)
    assert not any(c[0] == "launch" for c in server.calls)


def test_launch_defaults_to_server_host():
    server = FakeManager()
    desktop = FakeManager()
    status, body = handle_coding_request(
        "POST", "/launch", {"cwd": "/x", "prompt": "go"},
        manager=server,
        manager_for_host=lambda h: desktop if h == "desktop" else server)
    assert status == 200
    assert any(c[0] == "launch" for c in server.calls)


def test_terminal_start_unknown_session_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/nope/terminal/start", {}, manager=m)
    assert status == 404


def test_terminal_start_without_tmux_name_409():
    # the FakeManager's known session has host defaulting to 'server' and no
    # tmux_name -> 409 (no real tmux is ever spawned in this path)
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/terminal/start", {}, manager=m)
    assert status == 409


def test_restart_route_known_session():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/restart", {}, manager=m)
    assert status == 200 and body["ok"] is True
    assert any(c[0] == "restart" for c in m.calls)


def test_restart_route_unknown_session_404():
    m = FakeManager()
    status, body = handle_coding_request("POST", "/session/nope/restart", {}, manager=m)
    assert status == 404


def test_delete_route_known_session():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/delete", {}, manager=m)
    assert status == 200 and body["ok"] is True
    assert any(c[0] == "delete" for c in m.calls)


def test_delete_route_accepts_delete_method():
    m = FakeManager()
    status, body = handle_coding_request(
        "DELETE", "/session/" + FakeManager.KNOWN + "/delete", None, manager=m)
    assert status == 200


def test_launch_passes_skip_permissions():
    m = FakeManager()
    handle_coding_request("POST", "/launch",
                          {"cwd": "/x", "prompt": "go", "skip_permissions": True},
                          manager=m)
    launch_call = next(c for c in m.calls if c[0] == "launch")
    assert launch_call[1]["skip_permissions"] is True


def test_settings_route_updates():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/" + FakeManager.KNOWN + "/settings",
        {"skip_permissions": True, "cwd": "~/p",
         "sync": {"enabled": True, "device": "mac", "remote_path": "~/r"}},
        manager=m)
    assert status == 200 and body["ok"] is True
    call = next(c for c in m.calls if c[0] == "update_settings")
    assert call[2]["skip_permissions"] is True
    assert call[2]["sync"]["device"] == "mac"


def test_settings_route_unknown_session_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/nope/settings", {"skip_permissions": True}, manager=m)
    assert status == 404


# ── GET /projects?expand=sessions ───────────────────────────────────────────────

def test_get_projects_expand_groups_sessions_and_ungrouped():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    # one session in the project, one with no project (legacy) -> ungrouped
    m._sessions = [
        {"id": "s1", "status": "running", "title": "a", "project_id": pid},
        {"id": "s2", "status": "stopped", "title": "b", "project_id": None},
    ]
    status, body = handle_coding_request(
        "GET", "/projects?expand=sessions", None, manager=m)
    assert status == 200
    proj = body["projects"][0]
    assert [s["id"] for s in proj["sessions"]] == ["s1"]
    assert [s["id"] for s in body["ungrouped"]] == ["s2"]


def test_get_projects_expand_project_with_no_sessions():
    m = FakeManager()
    m.store.create_project(name="empty", repo_path="/r")
    m._sessions = []
    status, body = handle_coding_request(
        "GET", "/projects?expand=sessions", None, manager=m)
    assert status == 200
    assert body["projects"][0]["sessions"] == []
    assert body["ungrouped"] == []


def test_get_projects_no_expand_has_no_sessions_key():
    m = FakeManager()
    m.store.create_project(name="p", repo_path="/r")
    status, body = handle_coding_request("GET", "/projects", None, manager=m)
    assert "ungrouped" not in body
    assert "sessions" not in body["projects"][0]


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


# ── DELETE /project/<id> ────────────────────────────────────────────────────────

def test_delete_project_detaches_sessions_by_default():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.sessions = [
        {"id": "s1", "project_id": pid}, {"id": "s2", "project_id": pid}]
    status, body = handle_coding_request(
        "DELETE", "/project/" + str(pid), None, manager=m)
    assert status == 200 and body["ok"] is True
    # default = detach: sessions' project_id nulled, no manager.delete, project gone
    assert set(m.store.detached) == {"s1", "s2"}
    assert not any(c[0] == "delete" for c in m.calls)
    assert pid in m.store.deleted_projects


def test_delete_project_cascade_deletes_sessions():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.sessions = [{"id": "s1", "project_id": pid}]
    status, body = handle_coding_request(
        "DELETE", "/project/" + str(pid) + "?delete_sessions=1", None, manager=m)
    assert status == 200 and body["ok"] is True
    assert ("delete", "s1") in m.calls          # session was deleted
    assert m.store.detached == []               # NOT detached
    assert pid in m.store.deleted_projects


def test_delete_project_cascade_survives_already_gone_session():
    # manager.delete raising must not crash the cascade (best-effort).
    m = FakeManager(raise_on="delete", exc=KeyError("gone"))
    pid = m.store.create_project(name="p", repo_path="/r")
    m.store.sessions = [{"id": "s1", "project_id": pid}]
    status, body = handle_coding_request(
        "DELETE", "/project/" + str(pid) + "?delete_sessions=1", None, manager=m)
    assert status == 200 and body["ok"] is True
    assert pid in m.store.deleted_projects


def test_delete_project_unknown_404():
    m = FakeManager()
    status, body = handle_coding_request("DELETE", "/project/999", None, manager=m)
    assert status == 404


# ── POST /project/<id>/session ──────────────────────────────────────────────────

def test_launch_in_project_uses_repo_path_default_and_sets_project_id():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/the/repo")
    status, body = handle_coding_request(
        "POST", "/project/" + str(pid) + "/session",
        {"prompt": "go"}, manager=m)
    assert status == 200 and body["ok"] is True
    name, kw = next(c for c in m.calls if c[0] == "launch")
    assert kw["cwd"] == "/the/repo"          # default cwd = project repo_path
    assert kw["project_id"] == pid           # the new session is linked
    assert kw["initial_prompt"] == "go"


def test_launch_in_project_honours_explicit_cwd():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/the/repo")
    handle_coding_request(
        "POST", "/project/" + str(pid) + "/session",
        {"cwd": "/override"}, manager=m)
    _, kw = next(c for c in m.calls if c[0] == "launch")
    assert kw["cwd"] == "/override"


def test_launch_in_project_unknown_project_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/project/999/session", {"prompt": "go"}, manager=m)
    assert status == 404
    assert not any(c[0] == "launch" for c in m.calls)


def test_launch_in_project_selects_host_manager():
    server = FakeManager()
    desktop = FakeManager()
    pid = server.store.create_project(name="p", repo_path="/r")
    # mirror the project into the desktop fake's store-less path: route reads the
    # project off the DEFAULT manager, then launches on the host manager.
    picked = {}

    def manager_for_host(h):
        picked["h"] = h
        return desktop if h == "desktop" else server

    status, body = handle_coding_request(
        "POST", "/project/" + str(pid) + "/session",
        {"prompt": "go", "host": "desktop"},
        manager=server, manager_for_host=manager_for_host)
    assert status == 200
    assert picked["h"] == "desktop"
    assert any(c[0] == "launch" for c in desktop.calls)
    assert not any(c[0] == "launch" for c in server.calls)


def test_project_unknown_action_404():
    m = FakeManager()
    pid = m.store.create_project(name="p", repo_path="/r")
    status, body = handle_coding_request(
        "GET", "/project/" + str(pid) + "/bogus", None, manager=m)
    assert status == 404


# ── POST /session/<id>/resume ───────────────────────────────────────────────────

def _add_session(m, row):
    """Append a session row to the FakeManager so manager.status(id) finds it."""
    m._sessions.append(dict(row))


def test_resume_unknown_session_404():
    m = FakeManager()
    status, body = handle_coding_request(
        "POST", "/session/nope/resume", {}, manager=m)
    assert status == 404
    assert "error" in body


def test_resume_without_claude_session_id_400():
    m = FakeManager()
    _add_session(m, {"id": "sess-noid", "status": "idle",
                     "source": "discovered-transcript", "host": "desktop",
                     "claude_session_id": "", "device_id": "dev-1",
                     "cwd": "/w/n"})
    status, body = handle_coding_request(
        "POST", "/session/sess-noid/resume", {}, manager=m)
    assert status == 400
    assert "claude_session_id" in body["error"]


def test_resume_ok_drives_helper(monkeypatch):
    from api import coding_desktop as cd

    m = FakeManager()
    _add_session(m, {"id": "sess-tr", "status": "idle",
                     "source": "discovered-transcript", "host": "desktop",
                     "claude_session_id": "csid-abc", "device_id": "dev-1",
                     "cwd": "/w/hist"})

    seen = {}

    def _fake_resume(row, **kw):
        seen["row"] = row
        return {"id": row["id"], "status": "starting", "host": "desktop",
                "tmux_name": "jc-fresh", "source": "discovered-tmux"}

    monkeypatch.setattr(cd, "resume_discovered_session", _fake_resume, raising=True)
    # device resolution shouldn't even be needed (the row carries device_id), but
    # stub it so a fallback can't reach the real bridge.
    monkeypatch.setattr(cd, "resolve_desktop_device_id",
                        lambda preferred=None: "dev-1", raising=True)

    status, body = handle_coding_request(
        "POST", "/session/sess-tr/resume", {}, manager=m)
    assert status == 200
    assert body["ok"] is True
    assert body["session"]["status"] == "starting"
    assert body["session"]["tmux_name"] == "jc-fresh"
    # the route passed the row through to the helper with its own device_id
    assert seen["row"]["device_id"] == "dev-1"
    assert seen["row"]["claude_session_id"] == "csid-abc"


def test_resume_falls_back_to_resolved_device(monkeypatch):
    """When the row has no device_id, the route resolves the connected desktop."""
    from api import coding_desktop as cd

    m = FakeManager()
    _add_session(m, {"id": "sess-nodev", "status": "idle",
                     "source": "discovered-transcript", "host": "desktop",
                     "claude_session_id": "csid-z", "device_id": "",
                     "cwd": "/w/z"})

    monkeypatch.setattr(cd, "resolve_desktop_device_id",
                        lambda preferred=None: "mac-resolved", raising=True)
    seen = {}

    def _fake_resume(row, **kw):
        seen["device_id"] = row.get("device_id")
        return {"id": row["id"], "status": "starting", "tmux_name": "jc-x",
                "source": "discovered-tmux"}

    monkeypatch.setattr(cd, "resume_discovered_session", _fake_resume, raising=True)
    status, body = handle_coding_request(
        "POST", "/session/sess-nodev/resume", {}, manager=m)
    assert status == 200
    assert seen["device_id"] == "mac-resolved"


def test_resume_no_device_connected_409(monkeypatch):
    from api import coding_desktop as cd

    m = FakeManager()
    _add_session(m, {"id": "sess-off", "status": "idle",
                     "source": "discovered-transcript", "host": "desktop",
                     "claude_session_id": "csid-off", "device_id": "",
                     "cwd": "/w/off"})
    monkeypatch.setattr(cd, "resolve_desktop_device_id",
                        lambda preferred=None: None, raising=True)
    # The helper must never be called when no device is connected.
    def _boom(*a, **k):
        raise AssertionError("resume helper should not be called offline")
    monkeypatch.setattr(cd, "resume_discovered_session", _boom, raising=True)

    status, body = handle_coding_request(
        "POST", "/session/sess-off/resume", {}, manager=m)
    assert status == 409
    assert "error" in body
