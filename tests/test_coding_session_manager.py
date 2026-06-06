import types

import pytest

from agent.coding_session_manager import CodingSessionManager
from agent.coding_session_db import CodingSessionStore


class FakeDriver:
    name = "server"

    def __init__(self, returncode=0):
        self.calls = []
        self.returncode = returncode

    def claude_argv(self, *, plugin_dir, context_file, model, initial_prompt):
        return ["env", "claude", "--append-system-prompt-file", context_file]

    def tmux_new_argv(self, *, tmux_name, cwd, launch_argv):
        return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd] + list(launch_argv)

    def send_message_argvs(self, *, tmux_name, text):
        return [["tmux", "send-keys", "-t", tmux_name, "-l", "--", text],
                ["tmux", "send-keys", "-t", tmux_name, "Enter"]]

    def kill_argv(self, *, tmux_name):
        return ["tmux", "kill-session", "-t", tmux_name]

    def _run(self, argv):
        self.calls.append(argv)
        return types.SimpleNamespace(returncode=self.returncode, stderr="boom")


def _mgr(tmp_path, returncode=0):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))
    drv = FakeDriver(returncode=returncode)
    mgr = CodingSessionManager(
        store=store, driver=drv,
        plugin_dir="/repo/plugins/jarviscopilot-code-assist",
        memory_loader=lambda: ("mem", "usr"),
        context_root=str(tmp_path / "ctx"))
    return mgr, drv


def test_launch_writes_context_outside_repo(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt="do x", model="opus")
    assert s["status"] == "running"
    assert s["cwd"] == str(tmp_path)
    assert any(c[0] == "tmux" for c in drv.calls)
    # context file lives under context_root/<sid>/, NOT in the project cwd
    ctx = tmp_path / "ctx" / s["id"] / "JARVIS-CONTEXT.md"
    assert ctx.exists()
    assert "mem" in ctx.read_text()
    assert not (tmp_path / "JARVIS-CONTEXT.md").exists()


def test_launch_rejects_non_directory_cwd(tmp_path):
    mgr, _ = _mgr(tmp_path)
    with pytest.raises(ValueError):
        mgr.launch(cwd=str(tmp_path / "does-not-exist"), title="t",
                   initial_prompt=None, model=None)


def test_launch_failure_sets_error_status(tmp_path):
    mgr, _ = _mgr(tmp_path, returncode=1)
    with pytest.raises(RuntimeError):
        mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    # the only session recorded should be in 'error', not 'running'
    rows = mgr.list()
    assert rows and all(r["status"] == "error" for r in rows)


def test_send_message_issues_send_keys_and_stamps_activity(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    drv.calls.clear()
    mgr.send_message(s["id"], "run the tests")
    assert ["tmux", "send-keys", "-t", s["tmux_name"], "Enter"] in drv.calls
    assert mgr.status(s["id"])["last_activity_at"] is not None


def test_stop_marks_stopped_and_cleans_context(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    ctx = tmp_path / "ctx" / s["id"] / "JARVIS-CONTEXT.md"
    assert ctx.exists()
    mgr.stop(s["id"])
    assert mgr.status(s["id"])["status"] == "stopped"
    assert not ctx.exists()


def test_launch_captures_claude_session_id_when_capturer_set(tmp_path):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))
    mgr = CodingSessionManager(
        store=store, driver=FakeDriver(),
        plugin_dir="/p", memory_loader=lambda: ("m", "u"),
        context_root=str(tmp_path / "ctx"),
        session_capturer=lambda cwd, since: "claude-uuid-123")
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    assert s["claude_session_id"] == "claude-uuid-123"


def test_subagents_empty_without_claude_session_id(tmp_path):
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    assert mgr.subagents(s["id"]) == []


def _git_repo(path):
    import subprocess
    path.mkdir(parents=True, exist_ok=True)
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    import os
    e = {**os.environ, **env}
    subprocess.run(["git", "init"], cwd=path, check=True, capture_output=True, env=e)
    (path / "README.md").write_text("hi")
    subprocess.run(["git", "add", "-A"], cwd=path, check=True, capture_output=True, env=e)
    subprocess.run(["git", "commit", "-m", "init"], cwd=path, check=True,
                   capture_output=True, env=e)


def test_launch_with_worktree_isolates_session(tmp_path):
    repo = tmp_path / "repo"
    _git_repo(repo)
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd="/unused", title="t", initial_prompt=None, model=None,
                   worktree=True, repo_path=str(repo))
    assert s["worktree_path"]
    assert s["cwd"] == s["worktree_path"]
    import os
    assert os.path.isdir(s["worktree_path"])
