import types

import pytest

from agent.coding_session_manager import CodingSessionManager
from agent.coding_session_db import CodingSessionStore


class FakeDriver:
    name = "server"

    def __init__(self, returncode=0):
        self.calls = []
        self.returncode = returncode

    def claude_argv(self, *, plugin_dir, context_file, model, initial_prompt,
                    skip_permissions=False, resume=False, resume_session_id=None,
                    mcp_config=None):
        argv = ["env", "claude", "--append-system-prompt-file", context_file]
        if mcp_config:
            argv += ["--mcp-config", mcp_config]
        if resume:
            argv += ["--continue"]
        elif resume_session_id:
            argv += ["--resume", str(resume_session_id)]
        if initial_prompt and not resume and not resume_session_id:
            argv += [initial_prompt]
        return argv

    def tmux_new_argv(self, *, tmux_name, cwd, launch_argv):
        return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd] + list(launch_argv)

    def send_message_argvs(self, *, tmux_name, text):
        return [["tmux", "send-keys", "-t", tmux_name, "-l", "--", text],
                ["tmux", "send-keys", "-t", tmux_name, "Enter"]]

    def kill_argv(self, *, tmux_name):
        return ["tmux", "kill-session", "-t", tmux_name]

    def preflight(self):
        return None  # host always "ready" in unit tests

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


def test_launch_auto_links_a_project(tmp_path):
    # Every launched session lands in a project (auto-created from the cwd's
    # repo root) so the UI can group them. Two launches in the same folder
    # reuse ONE project.
    mgr, _ = _mgr(tmp_path)
    s1 = mgr.launch(cwd=str(tmp_path), title="a", initial_prompt=None, model=None)
    s2 = mgr.launch(cwd=str(tmp_path), title="b", initial_prompt=None, model=None)
    row1 = mgr.store.get_session(s1["id"])
    row2 = mgr.store.get_session(s2["id"])
    assert row1["project_id"] and row1["project_id"] == row2["project_id"]
    proj = mgr.store.get_project(row1["project_id"])
    assert proj is not None and proj["repo_path"]


def test_launch_auto_creates_missing_cwd(tmp_path):
    import os
    mgr, _ = _mgr(tmp_path)
    target = tmp_path / "new" / "nested" / "proj"   # does not exist yet
    s = mgr.launch(cwd=str(target), title="t", initial_prompt=None, model=None)
    assert s["status"] == "running"
    assert os.path.isdir(str(target))               # auto-created
    assert s["cwd"] == str(target)


def test_launch_expands_tilde(tmp_path, monkeypatch):
    import os
    # point HOME at tmp so ~ expansion is observable without touching real HOME
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd="~/proj", title="t", initial_prompt=None, model=None)
    expected = os.path.join(str(tmp_path / "home"), "proj")
    assert s["cwd"] == expected
    assert os.path.isdir(expected)


def test_launch_with_resume_session_id_adds_resume_flag(tmp_path):
    # Resuming a specific transcript: claude --resume <csid>, and the initial
    # prompt is suppressed (there's an existing conversation to continue).
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt="should be skipped",
                   model=None, resume_session_id="csid-XYZ")
    assert s["status"] == "running"
    launch = next(c for c in drv.calls if c[0] == "tmux")
    assert "--resume" in launch
    assert launch[launch.index("--resume") + 1] == "csid-XYZ"
    assert "should be skipped" not in launch     # initial prompt suppressed
    assert "--continue" not in launch            # not the restart path


def test_restart_resumes_stopped_session(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt="x", model=None)
    mgr.stop(s["id"])
    drv.calls.clear()
    r = mgr.restart(s["id"])
    assert r["status"] == "running"
    assert any("new-session" in c for c in drv.calls)   # a fresh tmux was started


def test_restart_preserves_skip_permissions(tmp_path):
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None,
                   skip_permissions=True)
    assert mgr.status(s["id"])["skip_permissions"] == 1
    mgr.stop(s["id"])
    mgr.restart(s["id"])
    assert mgr.status(s["id"])["skip_permissions"] == 1


def test_delete_removes_session(tmp_path):
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    mgr.delete(s["id"])
    assert mgr.status(s["id"]) is None


def test_update_settings_persists(tmp_path):
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    r = mgr.update_settings(s["id"], skip_permissions=True,
                            sync={"enabled": True, "device": "mac", "remote_path": "~/p"})
    assert r["skip_permissions"] == 1
    assert '"device": "mac"' in r["sync_config"]
    # disabling sync clears the config
    r2 = mgr.update_settings(s["id"], sync={"enabled": False})
    assert r2["sync_config"] is None


def test_update_settings_preserves_opaque_sync_keys(tmp_path):
    # A settings save (which only sends enabled/device/remote_path) must NOT drop
    # opaque keys like ``transcript`` that drive the server->Mac push-back.
    import json
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None,
                   sync={"enabled": True, "device": "mac", "remote_path": "/Users/me/p",
                         "transcript": {"csid": "abc", "device_cwd": "/Users/me/p"}})
    # the UI re-saves sync WITHOUT the transcript block
    r = mgr.update_settings(s["id"],
                            sync={"enabled": True, "device": "mac2",
                                  "remote_path": "/Users/me/p"})
    cfg = json.loads(r["sync_config"])
    assert cfg["device"] == "mac2"                     # user edit applied
    assert cfg["transcript"] == {"csid": "abc",        # opaque key preserved
                                 "device_cwd": "/Users/me/p"}


def test_launch_blocked_when_preflight_fails(tmp_path):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))

    class BadHost(FakeDriver):
        def preflight(self):
            return "tmux is not installed and could not be auto-installed."

    mgr = CodingSessionManager(
        store=store, driver=BadHost(), plugin_dir="/p",
        memory_loader=lambda: ("m", "u"), context_root=str(tmp_path / "ctx"))
    with pytest.raises(RuntimeError, match="tmux"):
        mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)


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


def test_launch_rejects_invalid_model(tmp_path):
    mgr, _ = _mgr(tmp_path)
    with pytest.raises(ValueError):
        mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None,
                   model="opus; rm -rf ~")


def test_worktree_cleaned_up_when_tmux_fails(tmp_path):
    import os
    repo = tmp_path / "repo"
    _git_repo(repo)
    mgr, _ = _mgr(tmp_path, returncode=1)  # tmux new-session "fails"
    with pytest.raises(RuntimeError):
        mgr.launch(cwd="/unused", title="t", initial_prompt=None, model=None,
                   worktree=True, repo_path=str(repo))
    rows = mgr.list()
    assert rows and rows[-1]["status"] == "error"
    # the orphan worktree was rolled back and unlinked from the row
    assert rows[-1]["worktree_path"] is None
    assert not (repo / ".jc-worktrees").exists() or not any((repo / ".jc-worktrees").iterdir())


def test_sync_starter_fires_for_any_host(tmp_path):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))
    calls = []
    mgr = CodingSessionManager(
        store=store, driver=FakeDriver(), plugin_dir="/p",
        memory_loader=lambda: ("m", "u"), context_root=str(tmp_path / "ctx"),
        sync_starter=lambda **kw: calls.append(kw))
    mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None,
               sync={"enabled": True, "device": "mac", "remote_path": "~/p"})
    assert calls and calls[0]["sync"]["device"] == "mac"
    assert calls[0]["cwd"] == str(tmp_path)


def _mgr_with_sync_stopper(tmp_path):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))
    stopped = []
    mgr = CodingSessionManager(
        store=store, driver=FakeDriver(), plugin_dir="/p",
        memory_loader=lambda: ("m", "u"), context_root=str(tmp_path / "ctx"),
        sync_stopper=lambda **kw: stopped.append(kw))
    return mgr, stopped


def test_stop_calls_sync_stopper(tmp_path):
    # SAFEGUARD: stopping a session must stop its file sync (else it orphans a
    # Mutagen sync that runs forever — the disk-fill root cause).
    mgr, stopped = _mgr_with_sync_stopper(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    mgr.stop(s["id"])
    assert stopped == [{"session_id": s["id"]}]


def test_delete_calls_sync_stopper(tmp_path):
    # The project-cascade-delete path calls delete() directly (bypassing the
    # route's explicit stop), so delete() must stop the sync too.
    mgr, stopped = _mgr_with_sync_stopper(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    mgr.delete(s["id"])
    assert stopped == [{"session_id": s["id"]}]


def test_launch_refuses_home_directory_cwd(tmp_path):
    mgr, _ = _mgr(tmp_path)
    import os
    for bad in (os.path.expanduser("~"), "/", "~"):
        try:
            mgr.launch(cwd=bad, title="t", initial_prompt=None, model=None)
            assert False, f"expected refusal for cwd={bad!r}"
        except ValueError as e:
            assert "home/system" in str(e)


def test_repo_root_never_leaks_server_cwd_for_empty():
    # An empty cwd must not resolve via ``git -C ''`` against the server's own
    # repo (which would misgroup the session). It returns the literal input.
    from agent.coding_session_manager import _repo_root
    assert _repo_root("") == ""


def test_repo_root_falls_back_for_missing_dir():
    from agent.coding_session_manager import _repo_root
    assert _repo_root("/no/such/dir/zzz") == "/no/such/dir/zzz"


def test_launch_does_not_block_when_git_missing(tmp_path, monkeypatch):
    # If git is slow/raises, _repo_root swallows it and the launch still
    # succeeds (grouped by the literal cwd). Force git to blow up.
    import subprocess
    import agent.coding_session_manager as m

    def boom(*a, **k):
        raise subprocess.TimeoutExpired(cmd="git", timeout=5)

    monkeypatch.setattr(subprocess, "run", boom)
    mgr, _ = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    assert s["status"] == "running"
    assert s["project_id"]  # still landed in an auto-created project


def test_launch_auto_project_is_race_safe(tmp_path):
    # Concurrent launches in the SAME folder must share ONE project (the store's
    # unique index + get_or_create make this atomic).
    import threading
    mgr, _ = _mgr(tmp_path)
    pids, barrier = [], threading.Barrier(6)

    def worker():
        barrier.wait()
        s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None,
                       model=None)
        pids.append(mgr.store.get_session(s["id"])["project_id"])

    threads = [threading.Thread(target=worker) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(set(pids)) == 1            # all sessions share one project
    assert len(mgr.store.list_projects()) == 1


def test_sync_starter_not_fired_without_sync(tmp_path):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))
    calls = []
    mgr = CodingSessionManager(
        store=store, driver=FakeDriver(), plugin_dir="/p",
        memory_loader=lambda: ("m", "u"), context_root=str(tmp_path / "ctx"),
        sync_starter=lambda **kw: calls.append(kw))
    mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    assert calls == []
