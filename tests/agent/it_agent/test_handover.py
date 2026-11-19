"""computer_do hands installs/setup on the PC to the IT agent; Mac goals and short PC tasks stay with the
fast hands, which suggest it_task when they hit their limits on the PC."""
import json

import pytest

from agent.computer import loop as L
from agent.it_agent import handover

HINT = "\nPast the fast hands' limits: for installs or multi-step setup on the PC, use it_task."


@pytest.mark.parametrize("goal,expected", [("install Docker Desktop", True), ("uninstall Discord", True),
                                           ("enable WSL2 on my PC", True), ("update drivers", True),
                                           ("open Spotify and play jazz", False),
                                           ("set up a meeting in Outlook", False),
                                           ("update the spreadsheet title", False)])
def test_past_limits(goal, expected):
    assert handover.past_limits(goal) is expected


def _rig(monkeypatch, os_name="windows", available=True, start_ok=True):
    from agent.computer import mac
    started = []
    monkeypatch.setattr(mac, "find_mac", lambda task_id=None: ("dev1", "Pranav-Desktop", None))
    monkeypatch.setattr(mac, "os_of", lambda did: os_name)
    monkeypatch.setattr(handover, "_available", lambda: available)
    monkeypatch.setattr(handover, "_start", lambda task_id, goal: started.append((task_id, goal))
                        or ({"ok": True, "job_id": "j1"} if start_ok else {"ok": False, "error": "no model"}))
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref)
    monkeypatch.setattr("tools.vision_tools._model_sees_images", lambda: False)
    return started


def test_computer_do_hands_installs_on_pc_to_it_agent(monkeypatch):
    started = _rig(monkeypatch)
    ran = []
    monkeypatch.setattr(L, "run", lambda *a, **k: ran.append(1))
    from tools import computer_do_tool as T
    out = json.loads(T.handle_computer_do({"goal": "install Docker Desktop"}, task_id="t1"))
    assert out["ok"] is True and out["handed_over"] == "it_task" and out["job_id"] == "j1"
    assert started == [("t1", "install Docker Desktop")] and not ran


def test_computer_do_keeps_mac_goals(monkeypatch):
    started = _rig(monkeypatch, os_name="macos")
    monkeypatch.setattr(L, "run", lambda goal, steps, cfg, **kw: L.Result("done", steps=[]))
    from tools import computer_do_tool as T
    out = json.loads(T.handle_computer_do({"goal": "install Raycast"}, task_id="t1"))
    assert out["ok"] is True and "handed_over" not in out and not started


def test_failed_hand_over_falls_back_to_the_fast_hands(monkeypatch):
    _rig(monkeypatch, start_ok=False)
    ran = []
    monkeypatch.setattr(L, "run", lambda goal, steps, cfg, **kw: ran.append(1) or L.Result("done", steps=[]))
    from tools import computer_do_tool as T
    T.handle_computer_do({"goal": "install Docker Desktop"}, task_id="t1")
    assert ran == [1]


def test_stuck_on_limit_suggests_it_task_when_available(monkeypatch):
    stuck = L.Result("stuck", reason="Reached the 30-move limit.")
    monkeypatch.setattr(handover, "_available", lambda: True)
    assert handover.limit_hint(stuck, "windows") == HINT
    assert handover.limit_hint(L.Result("stuck", reason="Ran out of time (120 s)."), "windows") == HINT
    assert handover.limit_hint(stuck, "macos") == ""
    assert handover.limit_hint(L.Result("stuck", reason="The button isn't there."), "windows") == ""
    monkeypatch.setattr(handover, "_available", lambda: False)
    assert handover.limit_hint(stuck, "windows") == ""
    _rig(monkeypatch)
    monkeypatch.setattr(L, "run", lambda goal, steps, cfg, **kw: L.Result("stuck", reason="Ran out of time (120 s).",
                                                                          steps=[]))
    from tools import computer_do_tool as T
    out = json.loads(T.handle_computer_do({"goal": "open Spotify and play jazz"}, task_id="t1"))
    assert "use it_task" in out["summary"]



def test_an_install_his_words_aim_at_the_pc_goes_to_it_even_from_the_mac(monkeypatch):
    # Live 2026-11-18: "install docker desktop on my pc", typed on the Mac, opened Edge on the Mac.
    started = _rig(monkeypatch, os_name="macos")
    from agent import mac_browser_gate
    monkeypatch.setattr(mac_browser_gate, "turn_text", lambda tid: "Can you install docker desktop on my pc")
    out = handover.maybe_hand_over("Can you install docker desktop on my pc", "t1")
    assert out and json.loads(out)["handed_over"] == "it_task" and started


def test_a_mac_install_from_the_mac_stays_with_the_fast_hands(monkeypatch):
    started = _rig(monkeypatch, os_name="macos")
    from agent import mac_browser_gate
    monkeypatch.setattr(mac_browser_gate, "turn_text", lambda tid: "install Rectangle on my mac")
    assert handover.maybe_hand_over("install Rectangle", "t1") is None and not started
