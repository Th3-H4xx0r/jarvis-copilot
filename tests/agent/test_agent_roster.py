"""A machine's list of live agent sessions updates who runs what."""
from agent.agent_conversations import Conversations, ckey_for
from agent.agent_roster import apply_roster
from agent.coding_session_db import CodingSessionStore


def _conv(tmp_path):
    return Conversations(CodingSessionStore(str(tmp_path / "c.db")))


def E(sid, **kw):
    return dict({"agent": "claude", "session_id": sid, "pid": 10, "kind": "interactive",
                 "cwd": "/m/app", "name": "Fix it", "terminal": {"term_program": "vscode"}}, **kw)


def test_roster_upserts_and_ends_missing(tmp_path):
    conv = _conv(tmp_path)
    changed = apply_roster(conv, "dev1", [E("a"), E("b")], now=10.0)
    assert set(changed) == {"claude|a", "claude|b"}
    row = conv.get("claude|a")
    assert row["owner"] == "dev1" and row["status"] == "live"
    assert row["run"]["pid"] == 10 and row["run"]["terminal"]["term_program"] == "vscode"
    assert row["title"] == "Fix it" and row["cwd"] == "/m/app"
    changed = apply_roster(conv, "dev1", [E("a")], now=20.0)
    assert changed == ["claude|b"]
    assert conv.get("claude|b")["status"] == "ended" and conv.get("claude|b")["ended_at"] == 20.0


def test_roster_never_revives_moved(tmp_path):
    conv = _conv(tmp_path)
    apply_roster(conv, "dev1", [E("a")], now=1.0)
    conv.set_owner(ckey_for("claude", "a"), "server", {"kind": "background", "bg_id": "x"})
    apply_roster(conv, "dev1", [E("a")], now=2.0)   # the stale Mac process still runs
    row = conv.get("claude|a")
    assert row["owner"] == "server" and row["run"]["bg_id"] == "x"
    apply_roster(conv, "dev1", [], now=3.0)          # Mac stops reporting it
    assert conv.get("claude|a")["status"] == "live"


def test_roster_leaves_moving_alone(tmp_path):
    conv = _conv(tmp_path)
    apply_roster(conv, "dev1", [E("a")], now=1.0)
    conv.mark("claude|a", "moving", prev_status="asleep")
    apply_roster(conv, "dev1", [], now=2.0)
    assert conv.get("claude|a")["status"] == "moving"


def test_roster_skips_entries_without_session_id(tmp_path):
    conv = _conv(tmp_path)
    assert apply_roster(conv, "dev1", [E("")], now=1.0) == []
