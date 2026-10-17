"""One record per agent conversation, whichever machine runs it."""
from agent.agent_conversations import Conversations, ckey_for
from agent.coding_session_db import CodingSessionStore


def _conv(tmp_path):
    return Conversations(CodingSessionStore(str(tmp_path / "c.db")))


def test_ckey_is_agent_and_session():
    assert ckey_for("claude", "abc") == "claude|abc"


def test_resume_on_other_host_is_same_row(tmp_path):
    conv = _conv(tmp_path)
    k = ckey_for("claude", "s1")
    conv.upsert(k, agent="claude", session_id="s1", owner="dev1", status="live", cwd="/m/p")
    conv.set_owner(k, "server", {"kind": "background", "bg_id": "x"})
    rows = conv.list_visible(now=1000.0)
    assert [r["ckey"] for r in rows] == [k]
    assert rows[0]["owner"] == "server"
    assert rows[0]["run"] == {"kind": "background", "bg_id": "x"}
    assert rows[0]["cwd"] == "/m/p"


def test_new_session_id_is_new_row(tmp_path):
    conv = _conv(tmp_path)
    conv.upsert(ckey_for("claude", "a"), agent="claude", session_id="a", owner="dev1")
    conv.upsert(ckey_for("claude", "b"), agent="claude", session_id="b", owner="dev1")
    assert len(conv.list_visible(now=0.0)) == 2


def test_list_visible_hides_ended_after_12h(tmp_path):
    conv = _conv(tmp_path)
    now = 100_000.0
    conv.upsert("claude|old", agent="claude", session_id="old", owner="dev1",
                status="ended", ended_at=now - 13 * 3600)
    conv.upsert("claude|recent", agent="claude", session_id="recent", owner="dev1",
                status="ended", ended_at=now - 11 * 3600)
    conv.upsert("claude|live", agent="claude", session_id="live", owner="dev1", status="live")
    keys = {r["ckey"] for r in conv.list_visible(now=now)}
    assert keys == {"claude|recent", "claude|live"}


def test_run_and_terminal_roundtrip_json(tmp_path):
    conv = _conv(tmp_path)
    run = {"kind": "interactive", "pid": 42, "shell_pid": 41,
           "terminal": {"term_program": "vscode", "iterm": ""}}
    conv.upsert("claude|r", agent="claude", session_id="r", owner="dev1", run=run)
    assert conv.get("claude|r")["run"] == run


def test_mark_keeps_previous_status(tmp_path):
    conv = _conv(tmp_path)
    conv.upsert("claude|m", agent="claude", session_id="m", owner="dev1", status="asleep")
    row = conv.mark("claude|m", "moving", prev_status="asleep")
    assert row["status"] == "moving" and row["prev_status"] == "asleep"


def test_by_owner(tmp_path):
    conv = _conv(tmp_path)
    conv.upsert("claude|a", agent="claude", session_id="a", owner="dev1")
    conv.upsert("claude|b", agent="claude", session_id="b", owner="server")
    assert [r["ckey"] for r in conv.by_owner("dev1")] == ["claude|a"]


def test_get_missing_is_none(tmp_path):
    assert _conv(tmp_path).get("claude|nope") is None


def test_presence_roundtrip(tmp_path):
    store = CodingSessionStore(str(tmp_path / "c.db"))
    store.put_presence("dev1", state="asleep", since=5.0, sessions=["claude|a"],
                       dismissed=["claude|b"], pushed_at=6.0, device_name="MacBook")
    p = store.get_presence("dev1")
    assert p["state"] == "asleep" and p["sessions"] == ["claude|a"]
    assert p["dismissed"] == ["claude|b"] and p["device_name"] == "MacBook"
    assert store.get_presence("nope") is None
