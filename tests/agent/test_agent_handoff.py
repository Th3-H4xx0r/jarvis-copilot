"""Continue on server, merge back, Continue on Mac — routed to the owner, never lossy."""
import base64

import pytest

from agent import transcript_mirror as tm
from agent.agent_conversations import Conversations
from agent.agent_delivery import Deliveries
from agent.agent_handoff import CARRY_ON, Handoff
from agent.agent_presence import Presence
from agent.coding_session_db import CodingSessionStore


class FakeClaude:
    def __init__(self, fail=False):
        self.started, self.sent, self.stopped, self.trusted, self.fail = [], [], [], [], fail
        self.live = []

    def ensure_trusted(self, cwd):
        self.trusted.append(cwd)

    def start(self, cwd, **kw):
        if self.fail:
            raise RuntimeError("claude refused")
        self.started.append((cwd, kw))
        return "bg123456"

    def send(self, bg_id, text, timeout=8.0):
        self.sent.append((bg_id, text))

    def stop(self, bg_id):
        self.stopped.append(bg_id)

    def roster(self):
        return self.live


class FakeCodex:
    def __init__(self, ok=True):
        self.ok = ok

    def available(self):
        return (True, "") if self.ok else (False, "Codex isn't logged in on the server")


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("JC_CODING_PROJECTS_ROOT", str(tmp_path / "cp"))
    store = CodingSessionStore(str(tmp_path / "c.db"))
    conv = Conversations(store)
    frames = []
    presence = Presence(store, conv, push=lambda p: None)
    claude = FakeClaude()
    deliveries = Deliveries(store)
    synced = {"ok": True}
    h = Handoff(conv, presence, claude, FakeCodex(), deliveries,
                send_frame=lambda dev, f: frames.append((dev, f)) or True,
                project_synced=lambda row: synced["ok"])
    return {"conv": conv, "h": h, "claude": claude, "frames": frames, "presence": presence,
            "deliveries": deliveries, "synced": synced, "tmp": tmp_path}


def _asleep(env, sid="s1", state="working", status="asleep", agent="claude"):
    ck = f"{agent}|{sid}"
    env["conv"].upsert(ck, agent=agent, session_id=sid, owner="dev1", status=status,
                       state=state, cwd="/Users/p/app", run={"kind": "interactive", "pid": 5})
    row = env["conv"].get(ck)
    tm.append_chunk(dict(row, server_cwd=tm.server_cwd_for("/Users/p/app")), 0, b'{"uuid":"a"}\n')
    return ck


def test_continue_asleep_resumes_and_sets_owner(env):
    ck = _asleep(env, state="idle")
    out = env["h"].continue_on_server(ck)
    assert out["ok"] is True
    row = env["conv"].get(ck)
    assert row["owner"] == "server" and row["status"] == "live"
    assert row["run"] == {"kind": "background", "bg_id": "bg123456"}
    assert row["moved_from"] == "dev1" and row["origin_cwd"] == "/Users/p/app"
    cwd, kw = env["claude"].started[0]
    assert cwd == str(env["tmp"] / "cp" / "app") and kw["resume_session_id"] == "s1"
    assert env["claude"].trusted == [cwd]


def test_continue_offline_needs_confirm(env):
    ck = _asleep(env, status="offline")
    out = env["h"].continue_on_server(ck)
    assert out["ok"] is False and out["reason"] == "confirm_offline"
    assert env["h"].continue_on_server(ck, confirm_offline=True)["ok"] is True


def test_continue_live_on_mac_refused(env):
    ck = _asleep(env, status="live")
    assert env["h"].continue_on_server(ck)["reason"] == "owner_awake"


def test_continue_unsynced_project_refused_with_reason(env):
    ck = _asleep(env)
    env["synced"]["ok"] = False
    out = env["h"].continue_on_server(ck)
    assert out["ok"] is False and out["reason"] == "not_synced" and out["error"]


def test_continue_codex_unavailable(env):
    ck = _asleep(env, agent="codex")
    env["h"].codex = FakeCodex(ok=False)
    out = env["h"].continue_on_server(ck)
    assert out["reason"] == "codex_unavailable" and "logged in" in out["error"]


def test_start_failure_rolls_back(env):
    ck = _asleep(env)
    env["h"].claude = FakeClaude(fail=True)
    out = env["h"].continue_on_server(ck)
    assert out["ok"] is False and out["reason"] == "start_failed"
    row = env["conv"].get(ck)
    assert row["owner"] == "dev1" and row["status"] == "asleep"


def test_working_session_gets_carry_on(env):
    ck = _asleep(env, state="working")
    env["h"].continue_on_server(ck)
    assert env["claude"].sent == [("bg123456", CARRY_ON)]
    assert CARRY_ON == "Carry on from where you left off."


def test_waiting_session_gets_no_message(env):
    ck = _asleep(env, state="approval")
    env["h"].continue_on_server(ck)
    assert env["claude"].sent == []


def test_routes_to_owner_never_other_device(env):
    ck = _asleep(env, status="live", state="idle")
    env["presence"].on_connect("dev1")
    out = env["h"].send(ck, "hello")
    assert out["state"] == "sent"
    dev, frame = env["frames"][-1]
    assert dev == "dev1" and frame["type"] == "agent_instruction" and frame["text"] == "hello"
    assert frame["delivery_id"] == out["id"]


def test_send_to_offline_owner_fails_with_reason(env):
    ck = _asleep(env, status="asleep", state="idle")
    out = env["h"].send(ck, "hello")
    assert out["state"] == "failed" and out["reason"] == "owner_offline"
    assert env["frames"] == []


def test_send_to_server_owner_uses_runtime(env):
    ck = _asleep(env, state="idle")
    env["h"].continue_on_server(ck)
    out = env["h"].send(ck, "next")
    assert out["state"] == "sent" and env["claude"].sent[-1] == ("bg123456", "next")


def test_restart_mid_handoff_recovers(env):
    ck = _asleep(env)
    env["conv"].mark(ck, "moving", prev_status="asleep", moving_to="server", server_cwd="/x")
    env["claude"].live = [{"session_id": "s1", "bg_id": "bgLIVE", "kind": "background"}]
    env["h"].recover()
    row = env["conv"].get(ck)
    assert row["status"] == "live" and row["owner"] == "server" and row["run"]["bg_id"] == "bgLIVE"
    ck2 = _asleep(env, sid="s2")
    env["conv"].mark(ck2, "moving", prev_status="asleep", moving_to="server")
    env["claude"].live = []
    env["h"].recover()
    assert env["conv"].get(ck2)["status"] == "asleep" and env["conv"].get(ck2)["owner"] == "dev1"


def test_merge_back_sent_on_connect(env):
    ck = _asleep(env, state="idle")
    env["h"].continue_on_server(ck)
    env["frames"].clear()
    env["h"].on_device_connect("dev1")
    types = [f["type"] for _, f in env["frames"]]
    assert types[0] == "agent_moved" and ck in env["frames"][0][1]["ckeys"]
    sync = [f for _, f in env["frames"] if f["type"] == "agent_transcript_sync"]
    data = b"".join(base64.b64decode(f["data_b64"]) for f in sync)
    assert data == b'{"uuid":"a"}\n' and sync[-1]["part"] == sync[-1]["parts"] - 1


def test_continue_on_mac_stops_server_and_merges(env):
    ck = _asleep(env, state="idle")
    env["h"].continue_on_server(ck)
    env["presence"].on_connect("dev1")
    env["frames"].clear()
    out = env["h"].continue_on_mac(ck)
    assert out["ok"] is True and env["claude"].stopped == ["bg123456"]
    assert env["conv"].get(ck)["status"] == "moving"
    assert any(f["type"] == "agent_transcript_sync" and f.get("then") == "resume_local"
               for _, f in env["frames"])
    env["h"].on_merge_done("dev1", ck, ok=True, then="resume_local")
    row = env["conv"].get(ck)
    assert row["owner"] == "dev1" and row["status"] == "live"
    resume = [f for _, f in env["frames"] if f["type"] == "agent_resume_local"]
    assert resume and resume[0]["session_id"] == "s1" and resume[0]["cwd"] == "/Users/p/app"


def test_continue_on_mac_needs_mac_online(env):
    ck = _asleep(env, state="idle")
    env["h"].continue_on_server(ck)
    out = env["h"].continue_on_mac(ck)
    assert out["ok"] is False and out["reason"] == "mac_offline"


def test_reverse_tail_after_new_server_turns(env):
    ck = _asleep(env, state="idle")
    env["h"].continue_on_server(ck)
    env["presence"].on_connect("dev1")
    env["h"].on_device_connect("dev1")
    row = env["conv"].get(ck)
    tm.append_chunk(row, tm.size(row), b'{"uuid":"b"}\n{"uuid":"c"')   # last line still being written
    env["frames"].clear()
    env["h"].push_reverse(ck)
    (dev, frame), = env["frames"]
    assert dev == "dev1" and frame["type"] == "agent_transcript_tail"
    assert base64.b64decode(frame["data_b64"]) == b'{"uuid":"b"}\n'
    env["frames"].clear()
    env["h"].push_reverse(ck)
    assert env["frames"] == []          # nothing new and complete yet


def test_reverse_tail_not_sent_while_mac_asleep(env):
    ck = _asleep(env, state="idle")
    env["h"].continue_on_server(ck)
    row = env["conv"].get(ck)
    tm.append_chunk(row, tm.size(row), b'{"uuid":"b"}\n')
    env["frames"].clear()
    env["h"].push_reverse(ck)
    assert env["frames"] == []
