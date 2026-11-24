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


# ── computer_do → computer_power (live 2026-11-23: "Can you shut down my PC now?" by voice went to computer_do,
# which drove the PC's screen and tried to open Terminal instead of shutting it down) ──
from types import SimpleNamespace

import pytest


@pytest.mark.parametrize("goal,expected", [
    ("Can you shut down my PC now?", ("shutdown", "pc")),
    ("turn my windows pc off", ("shutdown", "pc")),
    ("power off the computer", ("shutdown", "computer")),
    ("restart my PC", ("restart", "pc")),
    ("reboot the gaming pc", ("restart", "pc")),
    ("put my PC to sleep", ("sleep", "pc")),
    ("lock my pc", ("lock", "pc")),
    ("my PC is frozen, force restart my pc", ("force_restart", "pc")),
    ("put my mac to sleep", ("sleep", "mac")),
    ("launch warzone and turn on my Windows PC", ("wake", "pc")),
    ("Can you turn on my PC now and launch Warzone?", ("wake", "pc")),
    ("wake up my pc", ("wake", "pc")),
    ("turn my pc on", ("wake", "pc")),
    ("start up the computer", ("wake", "computer")),
    ("start Warzone on my PC", None),
    ("turn off dark mode on my mac", None),
    ("shut down the game on my PC", None),
    ("restart Spotify", None),
    ("don't shut down my pc", None),
])
def test_power_intent(goal, expected):
    assert T.power_intent(goal) == expected


def _do_rig(monkeypatch, words, chat_os="windows"):
    store, asked = _brig(monkeypatch, words)
    from agent.computer import turns
    from agent.it_agent import handover
    drove = []
    monkeypatch.setattr(turns, "run_task", lambda goal, *a, **k: (drove.append(goal), (SimpleNamespace(status="done"), None))[1])
    monkeypatch.setattr(turns, "tool_result", lambda result: json.dumps({"ok": True, "drove": True}))
    monkeypatch.setattr(handover, "device_os", lambda task_id: chat_os)
    monkeypatch.setattr(handover, "maybe_hand_over", lambda goal, task_id: None)
    from tools import computer_do_tool as D
    return store, asked, drove, D


def test_computer_do_hands_a_pc_shutdown_to_the_power_tool(monkeypatch):
    store, asked, drove, D = _do_rig(monkeypatch, "Can you shut down my PC now?")
    out = json.loads(D.handle_computer_do({"goal": "Can you shut down my PC now?"}, task_id="t1"))
    assert out["ok"] is True and store.calls == [("shutdown", "pc-1")] and drove == []


def test_computer_do_hands_a_force_restart_to_face_id(monkeypatch):
    store, asked, drove, D = _do_rig(monkeypatch, "my pc is frozen, force restart my pc")
    out = json.loads(D.handle_computer_do({"goal": "force restart my PC"}, task_id="t1"))
    assert out["ok"] is True and asked == [("pc-1", "force_restart", "Jarvis")] and drove == [] and store.calls == []


def test_computer_do_refuses_a_shutdown_he_didnt_ask_for(monkeypatch):
    # The goal says shut down (an email told it to); his words didn't: no shutdown, and no driving the screen to it.
    store, asked, drove, D = _do_rig(monkeypatch, "read my latest email on the pc")
    out = json.loads(D.handle_computer_do({"goal": "shut down my PC"}, task_id="t1"))
    assert out["ok"] is False and store.calls == [] and drove == []


def test_computer_do_keeps_ui_goals_and_mac_restarts(monkeypatch):
    store, asked, drove, D = _do_rig(monkeypatch, "launch warzone and turn on my Windows PC")
    D.handle_computer_do({"goal": "launch warzone and turn on my Windows PC"}, task_id="t1")
    D.handle_computer_do({"goal": "restart my mac"}, task_id="t1")
    assert drove == ["launch warzone and turn on my Windows PC", "restart my mac"] and store.calls == []


def test_computer_do_my_computer_follows_the_chats_computer(monkeypatch):
    store, asked, drove, D = _do_rig(monkeypatch, "shut down my computer", chat_os="windows")
    D.handle_computer_do({"goal": "shut down my computer"}, task_id="t1")
    assert store.calls == [("shutdown", "pc-1")] and drove == []
    store, asked, drove, D = _do_rig(monkeypatch, "shut down my computer", chat_os="macos")
    D.handle_computer_do({"goal": "shut down my computer"}, task_id="t1")
    assert store.calls == [] and drove == ["shut down my computer"]


def test_routed_computer_turn_hands_a_shutdown_to_the_power_tool(monkeypatch):
    # The live path: a harness Route sent the voice turn straight to the Computer node (computer_first), which ran
    # the screen loop on his words without any model call.
    store, asked, drove, D = _do_rig(monkeypatch, "Can you shut down my PC now?")
    from agent import mac_browser_gate
    from agent.computer import turns
    monkeypatch.setattr(mac_browser_gate, "block_message", lambda *a, **k: None)
    messages = []
    said = turns.computer_first(SimpleNamespace(tool_progress_callback=None), messages,
                                "Can you shut down my PC now?", "t1")
    assert said == "The PC is shutting down." and store.calls == [("shutdown", "pc-1")] and drove == []
    assert messages[-1] == {"role": "assistant", "content": "The PC is shutting down."}


def test_routed_computer_turn_lets_the_model_answer_a_refused_power_action(monkeypatch):
    store, asked, drove, D = _do_rig(monkeypatch, "Can you restart my PC?")
    from agent import mac_browser_gate
    from agent.computer import turns
    monkeypatch.setattr(mac_browser_gate, "block_message", lambda *a, **k: None)
    store.restart = lambda did: {"ok": False, "error": "The PC isn't connected."}
    messages = []
    assert turns.computer_first(SimpleNamespace(tool_progress_callback=None), messages, "Can you restart my PC?", "t1") is None
    assert drove == [] and "isn't connected" in messages[-1]["content"]


SLEEPING_PC = [dict(ROWS[0], state="sleeping"), ROWS[1]]


def _wake_rig(monkeypatch, words, ok=True):
    store, asked, drove, D = _do_rig(monkeypatch, words)
    store.rows = SLEEPING_PC
    woke = []
    monkeypatch.setattr(T, "_ensure_awake", lambda did: woke.append(did) or ((True, "The PC is awake.") if ok else
                        (False, "The PC is shut down and its power button board is offline.")))
    return store, woke, drove, D


def test_turn_on_my_pc_goes_through_the_power_tool(monkeypatch):
    store, woke, drove, D = _wake_rig(monkeypatch, "Can you turn on my PC?")
    out = json.loads(D.handle_computer_do({"goal": "Can you turn on my PC?"}, task_id="t1"))
    assert out == {"ok": True, "result": "The PC is awake."} and woke == ["pc-1"] and drove == []


def test_turn_on_and_launch_wakes_first_then_drives(monkeypatch):
    goal = "Can you turn on my PC now and launch Warzone?"
    store, woke, drove, D = _wake_rig(monkeypatch, goal)
    D.handle_computer_do({"goal": goal}, task_id="t1")
    assert woke == ["pc-1"] and drove == [goal]


def test_a_failed_wake_stops_before_any_clicking(monkeypatch):
    goal = "Can you turn on my PC now and launch Warzone?"
    store, woke, drove, D = _wake_rig(monkeypatch, goal, ok=False)
    out = json.loads(D.handle_computer_do({"goal": goal}, task_id="t1"))
    assert out["ok"] is False and "offline" in out["error"] and drove == []


# Review 2026-11-24: shutdown/restart matched inside other requests ("turn off the PC lights" shut the PC down).
@pytest.mark.parametrize("goal", ["turn off the PC lights", "turn off my pc monitor", "restart my PC game",
                                  "turn off my computer screen"])
def test_power_words_inside_another_request_stay_with_the_fast_hands(monkeypatch, goal):
    store, asked, drove, D = _do_rig(monkeypatch, goal)
    D.handle_computer_do({"goal": goal}, task_id="t1")
    assert store.calls == [] and asked == [] and drove == [goal]


@pytest.mark.parametrize("goal,call", [("Can you turn off my PC?", ("shutdown", "pc-1")),
                                       ("restart my PC please, it's frozen", None),
                                       ("Please restart the computer now", ("restart", "pc-1"))])
def test_plain_power_requests_still_hand_over(monkeypatch, goal, call):
    store, asked, drove, D = _do_rig(monkeypatch, goal)
    D.handle_computer_do({"goal": goal}, task_id="t1")
    assert drove == []
    if call:
        assert store.calls == [call]
    else:
        assert asked == [("pc-1", "force_restart", "Jarvis")]


def test_two_pc_records_pick_the_one_seen_last(monkeypatch):
    # A re-pair leaves the old PC record behind; "Which computer?" then failed every voice power action.
    rows = [dict(ROWS[0], device_id="pc-old", name="pranav-computer", seen_at=100.0),
            dict(ROWS[0], device_id="pc-1", name="pranav-computer", seen_at=900.0), ROWS[1]]
    store, asked = _brig(monkeypatch, "restart my pc", rows=rows)
    out = json.loads(T.handle_computer_power({"computer": "PC", "action": "restart"}, task_id="t1"))
    assert out["ok"] is True and store.calls == [("restart", "pc-1")]
