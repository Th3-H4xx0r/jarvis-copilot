"""TDD for the kanban -> Claude Coding Session spawn_fn.

The kanban dispatcher (``jarviscopilot_cli.kanban_db.dispatch_once``) calls a
pluggable ``spawn_fn(task, workspace, *, board=None)``. ``make_claude_spawn_fn``
returns such a callable that routes claude-flagged cards into a
``CodingSessionManager.launch(...)`` and everything else to a fallback spawn_fn.

These tests inject a FAKE manager + FAKE fallback so they never touch a real
claude/tmux or the real manager.
"""
import pytest

from agent.coding_kanban_spawn import make_claude_spawn_fn, _wants_claude


class FakeManager:
    """Records ``launch`` calls and returns a canned session row."""

    def __init__(self, session=None):
        self.calls = []
        self._session = session or {"id": "cs_x"}

    def launch(self, **kwargs):
        self.calls.append(kwargs)
        return dict(self._session)


class FakeFallback:
    """Records calls and returns a sentinel pid so we can assert pass-through."""

    def __init__(self, ret=4321):
        self.calls = []
        self._ret = ret

    def __call__(self, task, workspace, *, board=None):
        self.calls.append((task, workspace, board))
        return self._ret


class FakeLink:
    def __init__(self):
        self.calls = []

    def __call__(self, *, task_id, session_id):
        self.calls.append((task_id, session_id))


# --------------------------------------------------------------------------- #
# _wants_claude truth table
# --------------------------------------------------------------------------- #
def test_wants_claude_truth_table():
    assert _wants_claude({"runner": "claude"}) is True
    assert _wants_claude({"runner": "hermes"}) is False
    assert _wants_claude({"runner": ""}) is False
    assert _wants_claude({}) is False                 # runner absent
    assert _wants_claude({"runner": None}) is False
    # exact match only: not a substring / case match
    assert _wants_claude({"runner": "Claude"}) is False
    assert _wants_claude({"runner": "claude-code"}) is False


# --------------------------------------------------------------------------- #
# non-claude card -> fallback
# --------------------------------------------------------------------------- #
def test_non_claude_card_routes_to_fallback():
    mgr = FakeManager()
    fb = FakeFallback(ret=999)
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {"id": "t1", "title": "do thing", "runner": "hermes"}
    out = spawn(task, "/ws/t1", board="b")

    assert out == 999                       # fallback's return is returned
    assert fb.calls == [(task, "/ws/t1", "b")]
    assert mgr.calls == []                  # manager never touched


def test_card_with_no_runner_routes_to_fallback():
    mgr = FakeManager()
    fb = FakeFallback(ret=7)
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {"id": "t2", "title": "no runner key"}
    out = spawn(task, "/ws/t2")             # board defaults to None

    assert out == 7
    assert fb.calls == [(task, "/ws/t2", None)]
    assert mgr.calls == []


# --------------------------------------------------------------------------- #
# claude card with worktree -> manager.launch
# --------------------------------------------------------------------------- #
def test_claude_card_with_worktree_launches_session():
    mgr = FakeManager(session={"id": "cs_x", "status": "running"})
    fb = FakeFallback()
    link = FakeLink()
    spawn = make_claude_spawn_fn(mgr, fallback=fb, link=link)

    task = {
        "id": "t3",
        "title": "Refactor auth",
        "body": "split the module",
        "runner": "claude",
        "model_override": "opus",
        "workspace_path": "/ws/t3",
        "worktree_path": "/wt/t3",
        "worker_context": "RICH CONTEXT BLOB",
    }
    out = spawn(task, "/dispatch/ws", board="b")

    # fallback untouched; manager launched exactly once
    assert fb.calls == []
    assert len(mgr.calls) == 1
    call = mgr.calls[0]

    # worktree wins over workspace_path / dispatcher workspace
    assert call["cwd"] == "/wt/t3"
    assert call["title"] == "Refactor auth"
    assert call["model"] == "opus"
    # prompt uses the prebuilt worker_context and a kanban work instruction
    assert "RICH CONTEXT BLOB" in call["initial_prompt"]
    assert "t3" in call["initial_prompt"]            # task id referenced

    # link callback associated the session with the card
    assert link.calls == [("t3", "cs_x")]

    # the launched session dict is returned
    assert out == {"id": "cs_x", "status": "running"}


def test_claude_card_without_worker_context_builds_title_body_prompt():
    mgr = FakeManager()
    fb = FakeFallback()
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {
        "id": "t4",
        "title": "Fix the bug",
        "body": "NPE on startup",
        "runner": "claude",
        "worktree_path": "/wt/t4",
    }
    spawn(task, "/dispatch/ws")

    prompt = mgr.calls[0]["initial_prompt"]
    assert "Fix the bug" in prompt
    assert "NPE on startup" in prompt
    # no model_override -> model passed as None
    assert mgr.calls[0]["model"] is None


# --------------------------------------------------------------------------- #
# cwd resolution fallbacks
# --------------------------------------------------------------------------- #
def test_claude_card_falls_back_to_workspace_path():
    mgr = FakeManager()
    fb = FakeFallback()
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {
        "id": "t5",
        "title": "x",
        "runner": "claude",
        "workspace_path": "/ws/t5",       # no worktree_path
    }
    spawn(task, "/dispatch/ws")
    assert mgr.calls[0]["cwd"] == "/ws/t5"


def test_claude_card_falls_back_to_dispatcher_workspace():
    mgr = FakeManager()
    fb = FakeFallback()
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {"id": "t6", "title": "x", "runner": "claude"}  # no paths at all
    spawn(task, "/dispatch/ws")
    assert mgr.calls[0]["cwd"] == "/dispatch/ws"


def test_claude_card_with_no_cwd_raises():
    mgr = FakeManager()
    fb = FakeFallback()
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {"id": "t7", "title": "x", "runner": "claude"}
    with pytest.raises(ValueError):
        spawn(task, "")          # no worktree, no workspace_path, no dispatcher ws


def test_claude_card_uses_id_when_title_missing():
    mgr = FakeManager()
    fb = FakeFallback()
    spawn = make_claude_spawn_fn(mgr, fallback=fb)

    task = {"id": "t8", "runner": "claude", "worktree_path": "/wt/t8"}
    spawn(task, "/dispatch/ws")
    assert mgr.calls[0]["title"] == "t8"


# --------------------------------------------------------------------------- #
# link is optional
# --------------------------------------------------------------------------- #
def test_link_is_optional():
    mgr = FakeManager()
    fb = FakeFallback()
    spawn = make_claude_spawn_fn(mgr, fallback=fb)  # no link

    task = {"id": "t9", "title": "x", "runner": "claude", "worktree_path": "/wt/t9"}
    out = spawn(task, "/dispatch/ws")
    assert out == {"id": "cs_x"}            # no crash without a link callable
