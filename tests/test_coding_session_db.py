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
