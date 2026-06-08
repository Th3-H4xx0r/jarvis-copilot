import os
import sqlite3
import threading

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


def test_create_session_column_value_alignment(tmp_path):
    # Guards the INSERT VALUES tuple against silent column/value misalignment:
    # every distinct field must land in its OWN column.
    s = _store(str(tmp_path))
    sid = s.create_session(
        project_id="cp_x", host="desktop", cwd="/the/cwd",
        worktree_path="/the/wt", branch="feat", tmux_name="jc-z",
        source="manual", title="the-title", skip_permissions=True,
        sync_config='{"k":1}', device_id="devX", external=True,
        status="idle", claude_session_id="cuid")
    row = s.get_session(sid)
    assert row["project_id"] == "cp_x"
    assert row["host"] == "desktop"
    assert row["cwd"] == "/the/cwd"
    assert row["worktree_path"] == "/the/wt"
    assert row["branch"] == "feat"
    assert row["tmux_name"] == "jc-z"
    assert row["status"] == "idle"
    assert row["title"] == "the-title"
    assert row["source"] == "manual"
    assert row["skip_permissions"] == 1
    assert row["sync_config"] == '{"k":1}'
    assert row["device_id"] == "devX"
    assert row["external"] == 1
    assert row["claude_session_id"] == "cuid"


def test_schema_reinit_is_idempotent(tmp_path):
    # Re-running the migrations on an already-migrated db must not raise or
    # duplicate columns/indexes.
    p = os.path.join(str(tmp_path), "coding.db")
    db.CodingSessionStore(db_path=p)
    db.CodingSessionStore(db_path=p)
    s = db.CodingSessionStore(db_path=p)
    sid = s.create_session(project_id=None, host="server", cwd="/r", branch=None,
                           tmux_name="jc-x", source="chat", title="t")
    assert s.get_session(sid) is not None


def test_update_project_sync_enabled_false_disables(tmp_path):
    # Regression: update_project(sync_enabled=False) used to store 1 (enabled)
    # because the coercion only checked isinstance(v, bool). Both bool and int
    # forms must round-trip to the right 0/1.
    s = _store(str(tmp_path))
    pid = s.get_or_create_project_for_path(repo_path="/x/sync")
    s.update_project(pid, sync_enabled=True)
    assert s.get_project(pid)["sync_enabled"] == 1
    s.update_project(pid, sync_enabled=False)
    assert s.get_project(pid)["sync_enabled"] == 0
    s.update_project(pid, sync_enabled=1)
    assert s.get_project(pid)["sync_enabled"] == 1
    s.update_project(pid, sync_enabled=0)
    assert s.get_project(pid)["sync_enabled"] == 0


def test_get_or_create_project_is_race_safe(tmp_path):
    # Concurrent launches in the SAME repo must yield exactly one project, not
    # one-per-thread (the old SELECT-then-INSERT-in-separate-connections race).
    p = os.path.join(str(tmp_path), "coding.db")
    db.CodingSessionStore(db_path=p)  # ensure schema/index exist up front
    results = []
    barrier = threading.Barrier(8)

    def worker():
        st = db.CodingSessionStore(db_path=p)
        barrier.wait()
        results.append(
            st.get_or_create_project_for_path(repo_path="/race/repo",
                                               device_id="d1"))

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(set(results)) == 1                 # all got the SAME project
    s = db.CodingSessionStore(db_path=p)
    rows = [pr for pr in s.list_projects() if pr["repo_path"] == "/race/repo"]
    assert len(rows) == 1                          # only one row in the db


def test_unique_index_blocks_duplicate_get_or_create(tmp_path):
    # A second get_or_create for the same (repo_path, device_id) reuses the row;
    # a raw duplicate INSERT is rejected by the unique index.
    s = _store(str(tmp_path))
    a = s.get_or_create_project_for_path(repo_path="/x/uniq", device_id="d")
    b = s.get_or_create_project_for_path(repo_path="/x/uniq", device_id="d")
    assert a == b
    with sqlite3.connect(s.db_path) as c:
        try:
            c.execute(
                "INSERT INTO coding_projects(id,name,repo_path,host,created_at,"
                "sync_enabled,device_id) VALUES('cp_dupe','x','/x/uniq','server',"
                "9.0,0,'d')")
            raised = False
        except sqlite3.IntegrityError:
            raised = True
    assert raised


def test_create_project_duplicate_path_raises_clear_error(tmp_path):
    # An explicit second create for the same (repo_path, device_id) hits the
    # unique index; the store turns the raw IntegrityError into a clear
    # ValueError rather than leaking a cryptic SQLite message.
    import pytest
    s = _store(str(tmp_path))
    s.create_project(name="A", repo_path="/dup/path")
    with pytest.raises(ValueError, match="already exists"):
        s.create_project(name="B", repo_path="/dup/path")
    # a different device for the same path is still allowed
    s.create_project(name="C", repo_path="/dup/path", device_id="dev2")


def test_migration_dedupes_preexisting_duplicate_projects(tmp_path):
    # An OLD db (created by the racy code) may hold duplicate
    # (repo_path, device_id) project rows. Opening it must collapse them onto
    # the oldest project, re-point that group's sessions, and keep legacy
    # project_id=NULL sessions intact — all without erroring on index build.
    p = os.path.join(str(tmp_path), "coding.db")
    c = sqlite3.connect(p)
    c.executescript(
        "CREATE TABLE coding_projects (id TEXT PRIMARY KEY, name TEXT NOT NULL,"
        " repo_path TEXT NOT NULL, host TEXT NOT NULL DEFAULT 'server',"
        " default_branch TEXT, created_at REAL NOT NULL,"
        " sync_enabled INTEGER NOT NULL DEFAULT 0, sync_desktop_path TEXT,"
        " ignore_rules TEXT, device_id TEXT);"
        "CREATE TABLE coding_sessions (id TEXT PRIMARY KEY, project_id TEXT,"
        " host TEXT NOT NULL, cwd TEXT NOT NULL, worktree_path TEXT, branch TEXT,"
        " tmux_name TEXT, claude_session_id TEXT, status TEXT NOT NULL DEFAULT"
        " 'starting', title TEXT, source TEXT, created_at REAL NOT NULL,"
        " updated_at REAL NOT NULL, last_activity_at REAL,"
        " skip_permissions INTEGER NOT NULL DEFAULT 0, sync_config TEXT,"
        " device_id TEXT, external INTEGER NOT NULL DEFAULT 0);")
    c.execute("INSERT INTO coding_projects VALUES('cp_old','foo','/x/foo',"
              "'server',NULL,1.0,0,NULL,NULL,NULL)")
    c.execute("INSERT INTO coding_projects VALUES('cp_dup','foo','/x/foo',"
              "'server',NULL,2.0,0,NULL,NULL,NULL)")
    c.execute("INSERT INTO coding_sessions VALUES('cs_1','cp_dup','server',"
              "'/x/foo',NULL,NULL,'jc-1',NULL,'running','t','chat',1.0,1.0,"
              "NULL,0,NULL,NULL,0)")
    c.execute("INSERT INTO coding_sessions VALUES('cs_legacy',NULL,'server',"
              "'/x/foo',NULL,NULL,'jc-2',NULL,'running','old','chat',1.0,1.0,"
              "NULL,0,NULL,NULL,0)")
    c.commit()
    c.close()

    s = db.CodingSessionStore(db_path=p)
    rows = [pr for pr in s.list_projects() if pr["repo_path"] == "/x/foo"]
    assert len(rows) == 1 and rows[0]["id"] == "cp_old"   # oldest survives
    assert s.get_session("cs_1")["project_id"] == "cp_old"  # re-pointed
    assert s.get_session("cs_legacy")["project_id"] is None  # legacy intact
    # and get_or_create now reuses the surviving project
    assert s.get_or_create_project_for_path(repo_path="/x/foo") == "cp_old"


def test_activity_state_round_trips(tmp_path):
    s = _store(str(tmp_path))
    sid = s.create_session(project_id=None, host="server", cwd="/r", branch=None,
                           tmux_name="jc-x", source="chat", title="t")
    # default is NULL until the detector writes one
    assert s.get_session(sid)["activity_state"] is None
    s.update_session(sid, activity_state="working")
    assert s.get_session(sid)["activity_state"] == "working"
    s.update_session(sid, activity_state="waiting")
    assert s.get_session(sid)["activity_state"] == "waiting"
    # clearing it (offline) is allowed
    s.update_session(sid, activity_state=None)
    assert s.get_session(sid)["activity_state"] is None


def test_la_token_upsert_list_delete(tmp_path):
    s = _store(str(tmp_path))
    s.upsert_la_token("tok1", "devA")
    s.upsert_la_token("tok2", "devB")
    toks = {r["token"] for r in s.list_la_tokens()}
    assert toks == {"tok1", "tok2"}
    # a new token from the same device replaces the old one
    s.upsert_la_token("tok1b", "devA")
    toks = {r["token"] for r in s.list_la_tokens()}
    assert toks == {"tok1b", "tok2"}
    s.delete_la_token("tok2")
    assert {r["token"] for r in s.list_la_tokens()} == {"tok1b"}
    # blank token is ignored
    s.upsert_la_token("", "devA")
    assert {r["token"] for r in s.list_la_tokens()} == {"tok1b"}
