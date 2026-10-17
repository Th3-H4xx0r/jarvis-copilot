"""Every message is sent, queued, delivered or failed — never silently dropped."""
from agent.agent_delivery import Deliveries
from agent.coding_session_db import CodingSessionStore


def _d(tmp_path):
    return Deliveries(CodingSessionStore(str(tmp_path / "c.db")))


def test_delivery_marked_on_matching_prompt(tmp_path):
    d = _d(tmp_path)
    did = d.create("claude|a", "Fix  the\nbug ")
    d.mark(did, "sent")
    d.on_prompt("claude|a", "fix the bug")
    assert d.get(did)["state"] == "delivered"


def test_prompt_for_other_session_does_not_match(tmp_path):
    d = _d(tmp_path)
    did = d.create("claude|a", "hi")
    d.mark(did, "sent")
    d.on_prompt("claude|b", "hi")
    assert d.get(did)["state"] == "sent"


def test_delivery_failed_reason_kept(tmp_path):
    d = _d(tmp_path)
    did = d.create("claude|a", "hi")
    d.mark(did, "failed", reason="owner_offline")
    row = d.get(did)
    assert row["state"] == "failed" and row["reason"] == "owner_offline"
    assert [r["id"] for r in d.recent("claude|a")] == [did]


def test_delivered_never_downgraded(tmp_path):
    d = _d(tmp_path)
    did = d.create("claude|a", "hi")
    d.on_prompt("claude|a", "hi")
    d.mark(did, "sent")
    assert d.get(did)["state"] == "delivered"
