"""Tests for approval queue multi-entry support (issue #527).

Previously _pending[sid] held one entry, so simultaneous approvals overwrote
each other. This PR changes submit_pending() to append to a list and adds
approval_id so /api/approval/respond can target a specific entry.
"""
import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(REPO_ROOT))

MESSAGES_JS = (REPO_ROOT / "static" / "messages.js").read_text(encoding="utf-8")
INDEX_HTML = (REPO_ROOT / "static" / "index.html").read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Behaviour: api.approvals queue
# ---------------------------------------------------------------------------

class _Handler:
    def __init__(self):
        import io
        self.wfile = io.BytesIO()
        self.status = None
        self.headers = {}

    def send_response(self, status):
        self.status = status

    def send_header(self, *a):
        pass

    def end_headers(self):
        pass

    def json(self):
        return json.loads(self.wfile.getvalue().decode("utf-8"))


def _reset(r, sid):
    with r._lock:
        r._pending.pop(sid, None)


def _submit(r, sid, n):
    for i in range(1, n + 1):
        r.submit_pending(sid, {"command": f"cmd{i}", "pattern_key": f"p{i}",
                               "pattern_keys": [f"p{i}"], "description": f"d{i}"})


def test_pending_returns_head_and_count():
    from api import approvals as r
    sid = "test-pending-count-sid"
    _reset(r, sid)
    _submit(r, sid, 2)
    h = _Handler()
    r._handle_approval_pending(h, sid)
    out = h.json()
    assert out["pending"]["command"] == "cmd1"
    assert out["pending_count"] == 2
    _reset(r, sid)
    h = _Handler()
    r._handle_approval_pending(h, sid)
    assert h.json() == {"pending": None, "pending_count": 0}


def test_respond_without_id_pops_oldest():
    from api import approvals as r
    sid = "test-respond-oldest-sid"
    _reset(r, sid)
    _submit(r, sid, 2)
    r.respond_approval(sid, "deny")
    with r._lock:
        assert [e["command"] for e in r._pending[sid]] == ["cmd2"]
    r.respond_approval(sid, "deny", "no-such-id")
    with r._lock:
        assert sid not in r._pending


def test_respond_tolerates_legacy_single_dict_value():
    from api import approvals as r
    sid = "test-respond-legacy-sid"
    with r._lock:
        r._pending[sid] = {"command": "old", "pattern_key": "p"}
    h = _Handler()
    r._handle_approval_pending(h, sid)
    assert h.json() == {"pending": {"command": "old", "pattern_key": "p"}, "pending_count": 1}
    r.respond_approval(sid, "deny")
    with r._lock:
        assert sid not in r._pending


# ---------------------------------------------------------------------------
# Static-analysis: JavaScript frontend
# ---------------------------------------------------------------------------

def test_respond_sends_approval_id():
    """respondApproval() must include approval_id in the POST body."""
    assert "approval_id: approvalId" in MESSAGES_JS, \
        "respondApproval() must send approval_id in the POST body to /api/approval/respond"


def test_show_approval_card_accepts_count():
    """showApprovalCard must accept a pendingCount parameter."""
    assert re.search(r"function showApprovalCard\(pending,\s*pendingCount\)", MESSAGES_JS), \
        "showApprovalCard() must accept a pendingCount argument"


def test_show_approval_card_renders_counter():
    """showApprovalCard must display a '1 of N pending' counter when N > 1."""
    assert '"1 of " + pendingCount + " pending"' in MESSAGES_JS or \
           "'1 of ' + pendingCount + ' pending'" in MESSAGES_JS, \
        "showApprovalCard() must render '1 of N pending' counter for multiple queued approvals"


def test_approval_current_id_tracked():
    """_approvalCurrentId must be set and cleared around each approval."""
    assert "_approvalCurrentId" in MESSAGES_JS, \
        "_approvalCurrentId must track the approval_id of the currently displayed card"
    assert "_approvalCurrentId = pending.approval_id" in MESSAGES_JS or \
           "_approvalCurrentId = pending.approval_id || null" in MESSAGES_JS, \
        "_approvalCurrentId must be assigned from pending.approval_id"
    # Must be nulled on respond
    assert "_approvalCurrentId = null" in MESSAGES_JS, \
        "_approvalCurrentId must be cleared when respondApproval() is called"


def test_polling_passes_count_to_show():
    """The poll loop must pass pending_count to the owner-aware approval renderer."""
    assert "showApprovalForSession(sid, data.pending, data.pending_count" in MESSAGES_JS, \
        "Poll loop must pass data.pending_count through showApprovalForSession"


# ---------------------------------------------------------------------------
# HTML: counter element present
# ---------------------------------------------------------------------------

def test_approval_counter_element_exists():
    """index.html must contain an approvalCounter element."""
    assert 'id="approvalCounter"' in INDEX_HTML, \
        "index.html must contain an element with id='approvalCounter' for the '1 of N' display"


# ---------------------------------------------------------------------------
# Functional: multiple entries behave correctly
# ---------------------------------------------------------------------------

def test_multiple_approvals_both_surfaced():
    """Two submit_pending calls must produce two queued entries, not one."""
    import threading
    from api import approvals as r

    # Reset state
    sid = "test-multi-approval-sid"
    with r._lock:
        r._pending.pop(sid, None)

    r.submit_pending(sid, {"command": "cmd1", "pattern_key": "p1", "pattern_keys": ["p1"], "description": "d1"})
    r.submit_pending(sid, {"command": "cmd2", "pattern_key": "p2", "pattern_keys": ["p2"], "description": "d2"})

    with r._lock:
        queue = r._pending.get(sid)

    assert isinstance(queue, list), "After two submit_pending calls, _pending[sid] must be a list"
    assert len(queue) == 2, f"Expected 2 queued entries, got {len(queue)}"
    assert queue[0]["command"] == "cmd1"
    assert queue[1]["command"] == "cmd2"
    assert queue[0].get("approval_id"), "First entry must have an approval_id"
    assert queue[1].get("approval_id"), "Second entry must have an approval_id"
    assert queue[0]["approval_id"] != queue[1]["approval_id"], "Each entry must have a unique approval_id"

    # Cleanup
    with r._lock:
        r._pending.pop(sid, None)


def test_respond_by_approval_id_pops_correct_entry():
    """Responding with approval_id must remove only the targeted entry."""
    from api import approvals as r

    sid = "test-respond-by-id-sid"
    with r._lock:
        r._pending.pop(sid, None)

    r.submit_pending(sid, {"command": "cmd1", "pattern_key": "p1", "pattern_keys": ["p1"], "description": "d1"})
    r.submit_pending(sid, {"command": "cmd2", "pattern_key": "p2", "pattern_keys": ["p2"], "description": "d2"})

    with r._lock:
        queue = r._pending.get(sid, [])
        aid2 = queue[1]["approval_id"] if len(queue) > 1 else None

    assert aid2, "Second entry must have an approval_id"

    # Respond to the SECOND entry by its approval_id
    r.respond_approval(sid, "deny", aid2)

    with r._lock:
        remaining = r._pending.get(sid, [])

    assert len(remaining) == 1, "One entry should remain after popping the second"
    assert remaining[0]["command"] == "cmd1", "The remaining entry should be cmd1"

    # Cleanup
    with r._lock:
        r._pending.pop(sid, None)
