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
        self._next = 1

    def create_project(self, *, name, repo_path, host="server", default_branch=None):
        pid = self._next
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
               worktree=False, repo_path=None, skip_permissions=False):
        self.calls.append(
            ("launch", dict(cwd=cwd, title=title, initial_prompt=initial_prompt,
                            model=model, worktree=worktree, repo_path=repo_path,
                            skip_permissions=skip_permissions)))
        self._maybe_raise("launch")
        return {"id": "sess-new", "status": "running", "cwd": cwd,
                "title": title}

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
    assert body == {"ok": True, "project_id": 1}
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
