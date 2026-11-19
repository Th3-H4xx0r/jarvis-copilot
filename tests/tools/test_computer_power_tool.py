"""computer_power: 'put my PC to sleep' / 'wake my PC' are instant power actions (the Agents card's), never an
IT task (live 2026-11-18: both went to the IT agent, which slept the PC through a raw API — twice)."""
import json

from tools import computer_power_tool as T

ROWS = [{"device_id": "pc-1", "name": "pranav-computer", "os": "windows", "state": "awake"},
        {"device_id": "mac-1", "name": "Pranavs-MacBook-Pro.local", "os": "macos", "state": "sleeping"}]


class Store:
    def __init__(self):
        self.calls = []

    def list_payload(self, name_of):
        return {"mac": [dict(r) for r in ROWS], "password_requests": []}

    def wake(self, did):
        self.calls.append(("wake", did)); return {"ok": True, "sent": True, "via": "the Pod"}

    def let_sleep(self, did):
        self.calls.append(("sleep", did)); return {"ok": True, "delivered": True}

    def lock(self, did):
        self.calls.append(("lock", did)); return {"ok": True, "delivered": True}

    def unlock(self, did):
        self.calls.append(("unlock", did)); return {"ok": True}

    def keep_awake(self, did, on):
        self.calls.append(("keep", did, on)); return {"ok": True, "delivered": True}


def _rig(monkeypatch, words="put my pc to sleep"):
    store = Store()
    monkeypatch.setattr(T, "_store", lambda: store)
    monkeypatch.setattr(T, "_turn_text", lambda task_id: words)
    return store


def test_sleep_and_wake_the_pc(monkeypatch):
    store = _rig(monkeypatch)
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "sleep"}, task_id="t1"))
    assert out["ok"] is True and store.calls == [("sleep", "pc-1")]
    _rig(monkeypatch, "wake my pc")
    store = T._store()
    out = json.loads(T.handle_computer_power({"computer": "my PC", "action": "wake"}, task_id="t1"))
    assert out["ok"] is True and store.calls == [("wake", "pc-1")] and "Pod" in out["result"]


def test_picks_the_computer_by_name_or_kind(monkeypatch):
    store = _rig(monkeypatch, "wake my mac")
    T.handle_computer_power({"computer": "Mac", "action": "wake"}, task_id="t1")
    T.handle_computer_power({"computer": "pranav-computer", "action": "keep_awake_on"}, task_id="t1")
    assert store.calls == [("wake", "mac-1"), ("keep", "pc-1", True)]
    out = json.loads(T.handle_computer_power({"computer": "toaster", "action": "wake"}, task_id="t1"))
    assert out["ok"] is False and "pranav-computer" in out["error"]


def test_only_on_his_own_words(monkeypatch):
    store = _rig(monkeypatch, "summarize my email")
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "sleep"}, task_id="t1"))
    assert out["ok"] is False and store.calls == []


def test_lock_is_the_pcs(monkeypatch):
    _rig(monkeypatch, "lock my mac")
    out = json.loads(T.handle_computer_power({"computer": "Mac", "action": "lock"}, task_id="t1"))
    assert out["ok"] is False and "PC" in out["error"]


def test_a_pending_wake_says_when(monkeypatch):
    store = _rig(monkeypatch, "wake my pc")
    store.wake = lambda did: {"ok": True, "pending": True, "via": "the PC itself", "within_min": 15}
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "wake"}, task_id="t1"))
    assert out["ok"] is True and "15 minutes" in out["result"] and "the PC itself" in out["result"]
