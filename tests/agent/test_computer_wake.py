"""Waking a sleeping Mac/PC and waiting until it's ready before acting (live 2026-11-19: the voice turn sent the
wake signal, then tried to launch Battle.net the same instant, got "device not connected" and gave up)."""
from agent.computer import wake as W

PC_ROW = {"device_id": "pc", "name": "pranav-computer", "os": "windows", "state": "sleeping"}


class Store:
    def __init__(self, rows, out):
        self.rows, self.out, self.woke = rows, out, []

    def list_payload(self, name_of):
        return {"mac": self.rows}

    def wake(self, did):
        self.woke.append(did)
        return self.out


def _rig(monkeypatch, up_after=None, out=None, rows=None):
    store = Store(rows if rows is not None else [dict(PC_ROW)], out or {"ok": True, "sent": True, "via": "Jarvis Pod"})
    clock = {"t": 0.0}
    up = set()
    monkeypatch.setattr(W, "_store", lambda: store)
    monkeypatch.setattr(W, "_ready", lambda did: did in up)

    def sleep(s):
        clock["t"] += s
        if up_after is not None and clock["t"] >= up_after:
            up.add("pc")
    return store, (lambda: clock["t"]), sleep


def test_a_sleeping_pc_is_woken_and_waited_for(monkeypatch):
    store, clock, sleep = _rig(monkeypatch, up_after=20)
    ok, note = W.ensure_awake("pc", clock=clock, sleep=sleep)
    assert ok is True and store.woke == ["pc"] and "awake" in note


def test_an_awake_or_unknown_device_needs_nothing(monkeypatch):
    store, clock, sleep = _rig(monkeypatch, rows=[dict(PC_ROW, state="awake")])
    assert W.ensure_awake("pc", clock=clock, sleep=sleep) == (True, "") and store.woke == []
    assert W.ensure_awake("phone", clock=clock, sleep=sleep) == (True, "")


def test_it_says_plainly_when_the_pc_doesnt_come_up(monkeypatch):
    store, clock, sleep = _rig(monkeypatch, out={"ok": True, "pending": True, "via": "the PC itself", "within_min": 15})
    ok, note = W.ensure_awake("pc", wait_s=60, clock=clock, sleep=sleep)
    assert ok is False and "15 minutes" in note and "PC" in note


def test_a_wake_that_cant_be_sent_says_why(monkeypatch):
    store, clock, sleep = _rig(monkeypatch, out={"ok": False, "error": "No other computer is online to wake the PC."})
    assert W.ensure_awake("pc", clock=clock, sleep=sleep) == (False, "No other computer is online to wake the PC.")



def test_recent_turns_are_kept_per_chat():
    from agent import mac_browser_gate as g
    g.note_turn("chat-recent", "Can you turn on my PC and launch Battle.net")
    g.note_turn("chat-recent", "Launch it now.")
    g.note_turn("chat-recent", "Hold. Can you launch Call of Duty: Warzone.")
    assert g.recent_texts("chat-recent") == ["Launch it now.", "Can you turn on my PC and launch Battle.net"]
    assert g.recent_texts("chat-other") == []


class Unlocker:
    def __init__(self):
        self.unlocks = []

    def unlock(self, did):
        self.unlocks.append(did)
        return {"ok": True}


def _lock_rig(monkeypatch, states):
    seq = list(states)
    store = Unlocker()
    clock = {"t": 0.0}
    monkeypatch.setattr(W, "_store", lambda: store)
    monkeypatch.setattr(W, "_locked", lambda did: seq.pop(0) if len(seq) > 1 else seq[0])
    return store, (lambda: clock["t"]), (lambda s: clock.__setitem__("t", clock["t"] + s))


def test_a_locked_pc_is_unlocked_before_acting(monkeypatch):
    # Live 2026-11-20: woken from sleep, the PC sat at its lock screen and nothing unlocked it.
    store, clock, sleep = _lock_rig(monkeypatch, [True, True, False])
    ok, note = W.ensure_unlocked("pc", clock=clock, sleep=sleep)
    assert ok is True and store.unlocks == ["pc"] and "unlocked" in note


def test_an_unlocked_screen_or_an_old_client_needs_nothing(monkeypatch):
    store, clock, sleep = _lock_rig(monkeypatch, [False])
    assert W.ensure_unlocked("pc", clock=clock, sleep=sleep) == (True, "") and store.unlocks == []
    store, clock, sleep = _lock_rig(monkeypatch, [None])
    assert W.ensure_unlocked("pc", clock=clock, sleep=sleep) == (True, "") and store.unlocks == []


def test_a_pc_still_locked_says_it_needs_his_ok(monkeypatch):
    store, clock, sleep = _lock_rig(monkeypatch, [True])
    ok, note = W.ensure_unlocked("pc", wait_s=30, clock=clock, sleep=sleep)
    assert ok is False and "Face ID" in note and store.unlocks == ["pc"]
