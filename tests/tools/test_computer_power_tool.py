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
    out = json.loads(T.handle_computer_power({"computer": "my PC", "action": "wake"}, task_id="t1"))
    assert out == {"ok": True, "result": "The PC is already awake."}


def test_picks_the_computer_by_name_or_kind(monkeypatch):
    store = _rig(monkeypatch, "wake my mac")
    woke = []
    monkeypatch.setattr(T, "_ensure_awake", lambda did: woke.append(did) or (True, "The Mac is awake."))
    T.handle_computer_power({"computer": "Mac", "action": "wake"}, task_id="t1")
    T.handle_computer_power({"computer": "pranav-computer", "action": "keep_awake_on"}, task_id="t1")
    assert woke == ["mac-1"] and store.calls == [("keep", "pc-1", True)]
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
    _rig(monkeypatch, "wake my mac")
    monkeypatch.setattr(T, "_ensure_awake", lambda did: (False, "The Mac didn't come up yet; the PC itself picks up "
                                                                "the wake request within 15 minutes. Try again then."))
    out = json.loads(T.handle_computer_power({"computer": "Mac", "action": "wake"}, task_id="t1"))
    assert out["ok"] is False and "15 minutes" in out["error"]


def test_keep_awake_for_a_sleeping_computer_says_it_applies_later(monkeypatch):
    # Review: it said "isn't connected" (failed) yet the server kept it and applied it hours later.
    store = _rig(monkeypatch, "keep my pc awake")
    store.keep_awake = lambda did, on: {"ok": True, "delivered": False}
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "keep_awake_on"}, task_id="t1"))
    assert out["ok"] is True and "next" in out["result"]



def test_wake_needs_no_power_word_and_waits_until_ready(monkeypatch):
    # Live 2026-11-19: "Launch it now." — the wake was refused for lacking a power word, and the turn gave up.
    store = _rig(monkeypatch, "Launch it now.")
    ROWS[0]["state"] = "sleeping"
    try:
        monkeypatch.setattr(T, "_ensure_awake", lambda did: (True, "The PC is awake."))
        out = json.loads(T.handle_computer_power({"computer": "PC", "action": "wake"}, task_id="t1"))
        assert out == {"ok": True, "result": "The PC is awake."}
        out = json.loads(T.handle_computer_power({"computer": "PC", "action": "sleep"}, task_id="t1"))
        assert out["ok"] is False                       # sleeping still needs his own words
    finally:
        ROWS[0]["state"] = "awake"



def test_unlock_waits_and_says_what_really_happened(monkeypatch):
    # Live 2026-11-20: it said "Asked your iPhone for Face ID" while his permission unlocked it silently, and the
    # model stopped to wait for an approval that never came.
    _rig(monkeypatch, "unlock it")
    monkeypatch.setattr(T, "_ensure_unlocked", lambda did: (True, "The screen is unlocked now."))
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "unlock"}, task_id="t1"))
    assert out == {"ok": True, "result": "The PC is unlocked."}
    monkeypatch.setattr(T, "_ensure_unlocked", lambda did: (True, ""))
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "unlock"}, task_id="t1"))
    assert out == {"ok": True, "result": "The PC is already unlocked."}



# ── PC power button (spec 2026-11-23): clean restart/shutdown, force via Face ID, wake can boot ──
class ButtonStore(Store):
    def __init__(self, rows=None):
        super().__init__()
        self.rows = rows

    def list_payload(self, name_of):
        return {"mac": [dict(r) for r in (self.rows or ROWS)], "password_requests": []}

    def restart(self, did):
        self.calls.append(("restart", did)); return {"ok": True, "delivered": True}

    def shutdown(self, did):
        self.calls.append(("shutdown", did)); return {"ok": True, "delivered": True}


def _brig(monkeypatch, words, rows=None):
    store = ButtonStore(rows)
    monkeypatch.setattr(T, "_store", lambda: store)
    monkeypatch.setattr(T, "_turn_text", lambda task_id: words)
    asked = []
    monkeypatch.setattr(T, "_force_request",
                        lambda pc, action: asked.append((pc, action, "Jarvis")) or
                        {"ok": True, "approval": {"id": "a1", "command": action}})
    return store, asked


def test_restart_clean(monkeypatch):
    store, asked = _brig(monkeypatch, "restart my pc")
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "restart"}, task_id="t1"))
    assert out["ok"] is True and store.calls == [("restart", "pc-1")] and asked == []


def test_shutdown_clean(monkeypatch):
    store, _ = _brig(monkeypatch, "shut down my pc")
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "shutdown"}, task_id="t1"))
    assert out["ok"] is True and store.calls == [("shutdown", "pc-1")]


def test_force_off_needs_force_words(monkeypatch):
    store, asked = _brig(monkeypatch, "turn off my pc")
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "force_off"}, task_id="t1"))
    assert out["ok"] is False and "shutdown" in out["error"] and asked == [] and store.calls == []


def test_force_off_creates_approval(monkeypatch):
    store, asked = _brig(monkeypatch, "force off my pc, it's frozen")
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "force_off"}, task_id="t1"))
    assert out["ok"] is True and "Face ID" in out["result"]
    assert asked == [("pc-1", "force_off", "Jarvis")] and store.calls == []


def test_wake_off_pc_allowed(monkeypatch):
    rows = [dict(ROWS[0], state="off"), ROWS[1]]
    _brig(monkeypatch, "launch warzone", rows)
    woke = []
    monkeypatch.setattr(T, "_ensure_awake", lambda did: woke.append(did) or (True, "The PC is awake."))
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "wake"}, task_id="t1"))
    assert out["ok"] is True and woke == ["pc-1"]


def test_wake_starting_pc_waits(monkeypatch):
    rows = [dict(ROWS[0], state="awake", reason="starting"), ROWS[1]]
    _brig(monkeypatch, "wake my pc", rows)
    woke = []
    monkeypatch.setattr(T, "_ensure_awake", lambda did: woke.append(did) or (True, "The PC is awake."))
    T.handle_computer_power({"computer": "PC", "action": "wake"}, task_id="t1")
    assert woke == ["pc-1"]   # lit by the power button, but Jarvis isn't connected yet



def test_shutdown_needs_its_own_words(monkeypatch):
    store, _ = _brig(monkeypatch, "wake my pc and read my email")   # the email says "shut down the computer"
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "shutdown"}, task_id="t1"))
    assert out["ok"] is False and store.calls == []


def test_sleep_words_dont_unlock_restart(monkeypatch):
    store, _ = _brig(monkeypatch, "put my pc to sleep")
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "restart"}, task_id="t1"))
    assert out["ok"] is False and store.calls == []
