"""Discovery (the Mac's 5 s scan) must not overwrite the state of a session
whose hooks are talking — hooks are the source of truth, the scan the fallback."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import pytest  # noqa: E402

from agent.coding_session_db import CodingSessionStore  # noqa: E402
from api import coding_desktop  # noqa: E402

CWD = "/Users/p/code/app"


@pytest.fixture
def store(tmp_path):
    return CodingSessionStore(str(tmp_path / "c.db"))


def _transcript_row(store, csid="s1", status="running", act="working"):
    pid = store.get_or_create_project_for_path(repo_path=CWD, host="desktop", device_id="d1")
    rid = store.create_session(project_id=pid, host="desktop", cwd=CWD, branch=None,
                               tmux_name=None, source="discovered-transcript", title="app",
                               device_id="d1", external=True, status=status,
                               claude_session_id=csid)
    store.update_session(rid, activity_state=act)
    return rid


def _tmux_row(store, act="waiting"):
    pid = store.get_or_create_project_for_path(repo_path=CWD, host="desktop", device_id="d1")
    rid = store.create_session(project_id=pid, host="desktop", cwd=CWD, branch=None,
                               tmux_name="2", source="discovered-tmux", title="2",
                               device_id="d1", external=True, status="running",
                               claude_session_id="s9")
    store.update_session(rid, activity_state=act)
    return rid


def test_transcript_scan_leaves_a_hook_fresh_row_alone(store):
    rid = _transcript_row(store)
    coding_desktop.ingest_discovered("d1", [{"kind": "transcript", "claude_session_id": "s1",
                                             "cwd": CWD, "summary": "x", "live": False}],
                                     store=store, hook_fresh=lambda r: r == rid)
    row = store.get_session(rid)
    assert (row["status"], row["activity_state"]) == ("running", "working")


def test_transcript_scan_still_owns_rows_without_hooks(store):
    rid = _transcript_row(store)
    coding_desktop.ingest_discovered("d1", [{"kind": "transcript", "claude_session_id": "s1",
                                             "cwd": CWD, "summary": "x", "live": False}],
                                     store=store, hook_fresh=lambda r: False)
    row = store.get_session(rid)
    assert (row["status"], row["activity_state"]) == ("idle", None)


def test_tmux_scan_does_not_overwrite_hook_state(store):
    rid = _tmux_row(store, act="waiting")
    coding_desktop.ingest_discovered("d1", [{"kind": "tmux", "tmux_name": "2", "cwd": CWD,
                                             "activity_state": "idle"}],
                                     store=store, hook_fresh=lambda r: r == rid)
    assert store.get_session(rid)["activity_state"] == "waiting"


def test_tmux_scan_does_not_reclaim_the_csid_hooks_fixed(store):
    rid = _tmux_row(store)
    store.update_session(rid, claude_session_id="real")
    coding_desktop.ingest_discovered("d1", [{"kind": "tmux", "tmux_name": "2", "cwd": CWD,
                                             "claude_session_id": "guess", "activity_state": "idle"}],
                                     store=store, hook_fresh=lambda r: r == rid)
    assert store.get_session(rid)["claude_session_id"] == "real"
