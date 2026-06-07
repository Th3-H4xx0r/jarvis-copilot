import os

from agent import coding_session_db as db


def _store(tmp_path):
    return db.CodingSessionStore(db_path=os.path.join(tmp_path, "coding.db"))


def test_create_and_get_session(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="server", cwd="/repo",
                           branch="main", tmux_name="jc-abc", source="chat",
                           title="fix tests")
    row = s.get_session(sid)
    assert row["id"] == sid
    assert row["host"] == "server"
    assert row["cwd"] == "/repo"
    assert row["status"] == "starting"
    assert row["source"] == "chat"


def test_update_status_and_claude_id(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="server", cwd="/r",
                           branch=None, tmux_name="jc-x", source="chat", title="t")
    s.update_session(sid, status="running", claude_session_id="uuid-1")
    row = s.get_session(sid)
    assert row["status"] == "running"
    assert row["claude_session_id"] == "uuid-1"


def test_skip_permissions_persisted(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="server", cwd="/r", branch=None,
                           tmux_name="jc-x", source="chat", title="t",
                           skip_permissions=True)
    assert s.get_session(sid)["skip_permissions"] == 1


def test_delete_session(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="server", cwd="/r", branch=None,
                           tmux_name="jc-x", source="chat", title="t")
    s.delete_session(sid)
    assert s.get_session(sid) is None


def test_list_sessions_filters_by_status(tmp_path):
    s = _store(str(tmp_path))
    a = s.create_session(project_id=None, host="server", cwd="/a", branch=None,
                         tmux_name="jc-a", source="chat", title="a")
    b = s.create_session(project_id=None, host="server", cwd="/b", branch=None,
                         tmux_name="jc-b", source="chat", title="b")
    s.update_session(a, status="running")
    s.update_session(b, status="stopped")
    running = [r["id"] for r in s.list_sessions(status="running")]
    assert running == [a]
    assert len(s.list_sessions()) == 2


def test_sync_config_persisted(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="server", cwd="/r", branch=None,
                           tmux_name="jc-x", source="chat", title="t",
                           sync_config='{"enabled": true, "device": "mac", "remote_path": "~/p"}')
    row = s.get_session(sid)
    assert '"device": "mac"' in row["sync_config"]


# ── projects: auto-keying + update + session grouping ─────────────────────────


def test_get_or_create_project_idempotent_per_device(tmp_path):
    s = _store(str(tmp_path))
    p1 = s.get_or_create_project_for_path(repo_path="/x/foo", device_id="dev1")
    p2 = s.get_or_create_project_for_path(repo_path="/x/foo", device_id="dev1")
    p3 = s.get_or_create_project_for_path(repo_path="/x/foo", device_id="dev2")
    assert p1 == p2          # same folder + device → one project
    assert p1 != p3          # same folder, different device → distinct
    assert s.get_project(p1)["name"] == "foo"   # name from basename


def test_get_or_create_project_server_default(tmp_path):
    s = _store(str(tmp_path))
    a = s.get_or_create_project_for_path(repo_path="/srv/app")
    b = s.get_or_create_project_for_path(repo_path="/srv/app")
    assert a == b
    assert (s.get_project(a)["device_id"] or "") == ""


def test_update_project_fields(tmp_path):
    s = _store(str(tmp_path))
    pid = s.get_or_create_project_for_path(repo_path="/x/bar")
    s.update_project(pid, name="Bar", sync_enabled=True,
                     sync_desktop_path="/Users/me/bar", ignore_rules="node_modules")
    row = s.get_project(pid)
    assert row["name"] == "Bar"
    assert row["sync_enabled"] == 1
    assert row["sync_desktop_path"] == "/Users/me/bar"
    assert row["ignore_rules"] == "node_modules"


def test_list_sessions_filtered_by_project_and_device(tmp_path):
    s = _store(str(tmp_path))
    p1 = s.get_or_create_project_for_path(repo_path="/x/a", device_id="d1")
    p2 = s.get_or_create_project_for_path(repo_path="/x/b", device_id="d1")
    s.create_session(project_id=p1, host="desktop", cwd="/x/a", branch=None,
                     tmux_name="jc-1", source="discovered-tmux", title="a",
                     device_id="d1", external=True)
    s.create_session(project_id=p2, host="desktop", cwd="/x/b", branch=None,
                     tmux_name="jc-2", source="manual", title="b", device_id="d1")
    assert len(s.list_sessions(project_id=p1)) == 1
    assert len(s.list_sessions(device_id="d1")) == 2
    assert len(s.list_sessions(project_id=p2, device_id="d1")) == 1


def test_create_session_discovered_fields(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="desktop", cwd="/x/c",
                           branch=None, tmux_name="jc-c", source="discovered-tmux",
                           title="c", device_id="dev9", external=True,
                           status="running", claude_session_id="ccc")
    row = s.get_session(sid)
    assert row["external"] == 1 and row["device_id"] == "dev9"
    assert row["status"] == "running" and row["claude_session_id"] == "ccc"
