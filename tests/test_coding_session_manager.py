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
