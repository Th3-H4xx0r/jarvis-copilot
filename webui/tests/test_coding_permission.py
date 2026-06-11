"""Remote permission-approval relay: the in-memory pending store + the
/permission/* endpoints on handle_coding_request."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import pytest  # noqa: E402

from api import coding_permission as cp  # noqa: E402
from api.coding_routes import handle_coding_request  # noqa: E402


@pytest.fixture(autouse=True)
def _clean():
    cp._reset_for_tests()
    yield
    cp._reset_for_tests()


# ── pending store ────────────────────────────────────────────────────────────

def test_create_poll_resolve_allow():
    rid = cp.create_request(tool="Bash", summary="Bash: ls", session_id="s1",
                            cwd="/w")
    assert cp.poll(rid)["status"] == "pending"
    assert cp.resolve(rid, decision="allow") is True
    out = cp.poll(rid)
    assert out["status"] == "resolved" and out["decision"] == "allow"
    # consumed once delivered
    assert cp.poll(rid)["status"] == "expired"


def test_deny_with_reply_becomes_reason():
    rid = cp.create_request(tool="Write", summary="Write: x", session_id="s",
                            cwd="/w")
    cp.resolve(rid, decision="deny", message="do it in src/ instead")
    out = cp.poll(rid)
    assert out["decision"] == "deny"
    assert out["reason"] == "do it in src/ instead"


def test_resolve_rejects_bad_decision_and_unknown():
    rid = cp.create_request(tool="Bash", summary="x", session_id="s", cwd="/w")
    assert cp.resolve(rid, decision="maybe") is False
    assert cp.resolve("nope", decision="allow") is False


def test_eviction_prefers_unresolved_over_a_resolved_verdict():
    # A resolved-but-not-yet-polled verdict must survive a flood that overflows
    # the store — the hook hasn't picked it up yet.
    rid0 = cp.create_request(tool="Bash", summary="keep", session_id="s",
                             cwd="/w")
    cp.resolve(rid0, decision="allow")
    for i in range(cp._MAX_PENDING + 5):
        cp.create_request(tool="Bash", summary=str(i), session_id="s", cwd="/w")
    out = cp.poll(rid0)
    assert out["status"] == "resolved" and out["decision"] == "allow"


def test_list_pending_excludes_resolved():
    a = cp.create_request(tool="Bash", summary="a", session_id="s", cwd="/w")
    b = cp.create_request(tool="Edit", summary="b", session_id="s", cwd="/w")
    cp.resolve(a, decision="allow")
    pend = cp.list_pending()
    ids = [p["request_id"] for p in pend]
    assert b in ids and a not in ids


# ── endpoints ────────────────────────────────────────────────────────────────

class _Store:
    def __init__(self, *, remote, sessions=None):
        self._remote = remote
        self._sessions = sessions or []

    def get_setting(self, key, default=None):
        if key == "notifications":
            return {"remote_approvals": self._remote}
        return default

    def list_sessions(self, *, status=None, project_id=None, device_id=None):
        out = list(self._sessions)
        if device_id is not None:
            out = [s for s in out if s.get("device_id") == device_id]
        if status is not None:
            out = [s for s in out if s.get("status") == status]
        return out


class _Mgr:
    def __init__(self, store):
        self.store = store


def test_request_disabled_by_default():
    m = _Mgr(_Store(remote=False))
    st, body = handle_coding_request(
        "POST", "/permission/request",
        {"tool": "Bash", "input": {"command": "ls"}}, manager=m)
    assert st == 200
    assert body["disabled"] is True and body["request_id"] is None


def test_request_when_enabled_holds_and_resolves():
    sess = {"id": "sess-X", "status": "running", "tmux_name": "19",
            "device_id": "dev1", "cwd": "/w/proj"}
    m = _Mgr(_Store(remote=True, sessions=[sess]))
    st, body = handle_coding_request(
        "POST", "/permission/request",
        {"tool": "Bash", "input": {"command": "rm -rf build"},
         "tmux_name": "19", "device_id": "dev1", "cwd": "/w/proj"}, manager=m)
    assert st == 200 and body["ok"] is True
    rid = body["request_id"]
    assert rid  # a request was held
    # it shows up in pending (for the in-app card), tied to the matched session
    st, pend = handle_coding_request("GET", "/permission/pending", None, manager=m)
    rows = pend["pending"]
    assert any(r["request_id"] == rid and r["session_id"] == "sess-X"
               and r["summary"].startswith("Bash:") for r in rows)
    # mobile posts a verdict; the hook poll then sees it
    st, v = handle_coding_request(
        "POST", "/permission/verdict",
        {"request_id": rid, "decision": "allow"}, manager=m)
    assert v["ok"] is True
    st, poll = handle_coding_request(
        "GET", "/permission/poll?request_id=" + rid, None, manager=m)
    assert poll["status"] == "resolved" and poll["decision"] == "allow"


def test_poll_requires_request_id():
    m = _Mgr(_Store(remote=True))
    st, _ = handle_coding_request("GET", "/permission/poll", None, manager=m)
    assert st == 400
