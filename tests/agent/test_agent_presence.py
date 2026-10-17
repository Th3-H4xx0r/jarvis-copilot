"""Whether a Mac is awake, asleep or offline, and the card + push that follow."""
from agent.agent_conversations import Conversations
from agent.agent_presence import Presence
from agent.coding_session_db import CodingSessionStore


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def _setup(tmp_path, live=("a", "b")):
    store = CodingSessionStore(str(tmp_path / "c.db"))
    conv = Conversations(store)
    for sid in live:
        conv.upsert(f"claude|{sid}", agent="claude", session_id=sid, owner="dev1", status="live")
    pushes, clock = [], Clock()
    return store, conv, Presence(store, conv, clock=clock, push=pushes.append), pushes, clock


def test_sleep_marks_asleep_and_pushes_once(tmp_path):
    _, conv, pres, pushes, _ = _setup(tmp_path)
    pres.on_sleep("dev1", "MacBook")
    pres.on_disconnect("dev1")
    pres.tick()
    assert conv.get("claude|a")["status"] == "asleep"
    assert pushes == [{"device_id": "dev1", "device_name": "MacBook", "kind": "sleep", "count": 2}]
    card = pres.card()
    assert card["kind"] == "sleep" and sorted(card["sessions"]) == ["claude|a", "claude|b"]
    assert card["device_name"] == "MacBook"


def test_no_push_when_nothing_live(tmp_path):
    _, _, pres, pushes, _ = _setup(tmp_path, live=())
    pres.on_sleep("dev1", "MacBook")
    assert pushes == [] and pres.card() is None


def test_offline_after_grace_only(tmp_path):
    _, conv, pres, pushes, clock = _setup(tmp_path)
    pres.on_disconnect("dev1")
    clock.t += 30
    pres.tick()
    assert conv.get("claude|a")["status"] == "live" and pushes == []
    clock.t += 31
    pres.tick()
    pres.tick()
    assert conv.get("claude|a")["status"] == "offline"
    assert [p["kind"] for p in pushes] == ["offline"] and pres.card()["kind"] == "offline"


def test_quick_reconnect_is_not_offline(tmp_path):
    _, conv, pres, pushes, clock = _setup(tmp_path)
    pres.on_disconnect("dev1")
    clock.t += 20
    pres.on_connect("dev1")
    clock.t += 100
    pres.tick()
    assert conv.get("claude|a")["status"] == "live" and pushes == []


def test_connect_clears_card_and_revives(tmp_path):
    _, conv, pres, _, _ = _setup(tmp_path)
    pres.on_sleep("dev1", "MacBook")
    revived = pres.on_connect("dev1")
    assert sorted(revived) == ["claude|a", "claude|b"]
    assert conv.get("claude|a")["status"] == "live" and pres.card() is None


def test_continue_removes_from_card(tmp_path):
    _, conv, pres, _, _ = _setup(tmp_path)
    pres.on_sleep("dev1", "MacBook")
    conv.set_owner("claude|a", "server", {"kind": "background"})
    assert pres.card()["sessions"] == ["claude|b"]
    pres.dismiss("dev1", ["claude|b"])
    assert pres.card() is None


def test_dismiss_all(tmp_path):
    _, _, pres, _, _ = _setup(tmp_path)
    pres.on_sleep("dev1", "MacBook")
    pres.dismiss("dev1")
    assert pres.card() is None


def test_card_survives_restart(tmp_path):
    store, conv, pres, _, clock = _setup(tmp_path)
    pres.on_sleep("dev1", "MacBook")
    again = Presence(store, conv, clock=clock, push=lambda _p: None)
    assert again.card()["kind"] == "sleep"
