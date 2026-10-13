"""The fast loop: look → decide → act on a fake Mac with scripted deciders."""
from agent.computer import loop as L
from agent.computer.decide import Move


def _look(n, sig=None, els=None):
    return {"ok": True, "look_id": f"L{n}", "app": "Calc", "window": "Calc", "sig": sig or f"s{n}",
            "base64": "", "elements": els or [{"i": 1, "role": "AXButton", "label": "7"},
                                              {"i": 2, "role": "AXButton", "label": "="}]}


class FakeMac:
    def __init__(self, act_results=None):
        self.n = 0
        self.acts = []
        self.act_results = list(act_results or [])

    def look(self, device, app=None):
        self.n += 1
        return _look(self.n)

    def act(self, device, action, look_id):
        self.acts.append((action, look_id))
        if self.act_results:
            r = self.act_results.pop(0)
            if r is not None:
                return r
        self.n += 1
        return {"ok": True, "did": action["action"], "via": "ax", "look": _look(self.n)}


def _cfg(**kw):
    return L.Config(decision_ref="@d:m", fallback_ref="@f:m", **kw)


def _decider(*moves):
    seq = list(moves)
    calls = []

    def fn(ref, look, goal, step, history, **kw):
        calls.append(step.get("do"))
        return seq.pop(0) if seq else Move({"action": "done"}, 0.9, "decision", 5)
    fn.calls = calls
    return fn


def _never(*a, **k):
    raise AssertionError("fallback should not run")


def test_done_path_opens_app_directly_and_reports():
    mac = FakeMac()
    lines = []
    decide = _decider(Move({"action": "click", "element": 1}, 0.9, "decision", 10),
                      Move({"action": "done"}, 0.95, "decision", 10),
                      Move({"action": "done"}, 0.95, "decision", 10))
    r = L.run("work out 7", [{"do": "open Calculator", "app": "Calculator"}, {"do": "press 7"}], _cfg(),
              device="mac1", progress=lines.append, decide=decide, fallback=_never, mac=mac)
    assert r.status == "done"
    assert mac.acts[0][0] == {"action": "open_app", "app": "Calculator"}
    assert mac.acts[1][0] == {"action": "click", "element": 1}
    assert len(r.actions) == 2 and len(lines) == 2
    assert "button '7'" in lines[1]


def test_loop_low_conf_uses_fallback():
    mac = FakeMac()
    used = []

    def fallback(ref, look, goal, step, history, **kw):
        used.append(ref)
        return Move({"action": "click", "element": 2}, None, "fallback", 50)

    decide = _decider(Move({"action": "click", "element": 1}, 0.3, "decision", 10))
    r = L.run("g", [{"do": "press ="}], _cfg(), device="m", decide=decide, fallback=fallback, mac=mac)
    assert used == ["@f:m"] and mac.acts[0][0] == {"action": "click", "element": 2}
    assert r.status == "done" and r.actions[0]["by"] == "fallback"


def test_fallback_stuck_twice_stops():
    mac = FakeMac()

    def fallback(*a, **k):
        return Move({"action": "stuck"}, None, "fallback", 50, why="no such button")

    decide = _decider(*[Move({"action": "stuck"}, 0.9, "decision", 10)] * 5)
    r = L.run("g", [{"do": "press ×"}], _cfg(), device="m", decide=decide, fallback=fallback, mac=mac)
    assert r.status == "stuck" and "no such button" in r.reason


def test_same_move_with_no_change_three_times_stops():
    same = {"ok": True, "did": "click", "via": "ax", "look": _look(1, sig="same")}
    mac = FakeMac(act_results=[same, same, same, same])
    mac.look = lambda device, app=None: _look(1, sig="same")
    decide = _decider(*[Move({"action": "click", "element": 1}, 0.9, "decision", 10)] * 5)
    r = L.run("g", [{"do": "x"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "stuck" and "nothing" in r.reason and len(mac.acts) == 3


def test_max_actions():
    mac = FakeMac()
    decide = _decider(*[Move({"action": "scroll", "direction": "down"}, 0.9, "decision", 1)] * 10)
    r = L.run("g", [{"do": "x"}], _cfg(max_actions=3), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "stuck" and "3" in r.reason and len(mac.acts) == 3


def test_should_stop():
    r = L.run("g", [{"do": "x"}], _cfg(), device="m", should_stop=lambda: True,
              decide=_decider(), fallback=_never, mac=FakeMac())
    assert r.status == "error" and r.reason == "stopped"


def test_loop_device_error_stops():
    mac = FakeMac(act_results=[{"ok": False, "error": "MacBook is offline right now.", "device": True}])
    decide = _decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1))
    r = L.run("g", [{"do": "x"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "error" and "offline" in r.reason


def test_loop_relooks_on_stale_look():
    mac = FakeMac(act_results=[{"ok": False, "error": "That screen is gone; look again."}])
    decide = _decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1),
                      Move({"action": "click", "element": 1}, 0.9, "decision", 1))
    r = L.run("g", [{"do": "x"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "done" and len(mac.acts) == 2 and mac.acts[1][1] != mac.acts[0][1]


def test_blocked_key_combo_refused():
    mac = FakeMac()
    decide = _decider(Move({"action": "key", "keys": "cmd+shift+q"}, 0.9, "decision", 1))

    def fallback(*a, **k):
        return Move({"action": "key", "keys": "cmd+shift+q"}, None, "fallback", 1)

    r = L.run("g", [{"do": "x"}], _cfg(), device="m", decide=decide, fallback=fallback, mac=mac)
    assert r.status == "stuck" and "cmd+shift+q" in r.reason and mac.acts == []


def test_no_steps_plans_first():
    mac = FakeMac()
    seen = {}

    def plan(ref, goal, look, **kw):
        seen["ref"] = ref
        return {"steps": [{"do": "press 7"}], "say": "It's 7."}

    r = L.run("on my mac press 7", None, _cfg(), device="m", decide=_decider(), fallback=_never, mac=mac,
              plan=plan)
    assert seen["ref"] == "@f:m" and r.status == "done" and r.say == "It's 7."


def test_no_decision_model_goes_straight_to_fallback():
    mac = FakeMac()
    seq = [Move({"action": "click", "element": 1}, None, "fallback", 5), Move({"action": "done"}, None, "fallback", 5)]
    r = L.run("g", [{"do": "x"}], L.Config(decision_ref=None, fallback_ref="@f:m"), device="m",
              decide=_never, fallback=lambda *a, **k: seq.pop(0), mac=mac)
    assert r.status == "done" and len(mac.acts) == 1


def test_summary_mentions_status_moves_and_elements():
    mac = FakeMac()
    r = L.run("g", [{"do": "press 7"}], _cfg(), device="m",
              decide=_decider(Move({"action": "click", "element": 1}, 0.9, "decision", 400)),
              fallback=_never, mac=mac)
    s = r.summary()
    assert "done" in s.lower() and "button '7'" in s and "look_id" in s


class AppMac(FakeMac):
    """Records which app every look asked for."""

    def __init__(self, act_results=None):
        super().__init__(act_results)
        self.looked = []

    def look(self, device, app=None):
        self.looked.append(app)
        self.n += 1
        return {**_look(self.n), "app": app or "Brave Browser"}

    def act(self, device, action, look_id):
        self.acts.append((action, look_id))
        if self.act_results:
            r = self.act_results.pop(0)
            if r is not None:
                return r
        self.n += 1
        return {"ok": True, "did": action["action"], "via": "ax",
                "look": {**_look(self.n), "app": action.get("app") or "Calculator"}}


def test_loop_anchors_to_the_task_app_when_he_switches_away():
    """He swiped to another app mid-task: every later look is still Calculator's."""
    mac = AppMac(act_results=[None, {"ok": True, "did": "click", "via": "ax"}])
    decide = _decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1),
                      Move({"action": "done"}, 0.9, "decision", 1))
    r = L.run("g", [{"do": "open Calculator", "app": "Calculator"}], _cfg(), device="m", decide=decide,
              fallback=_never, mac=mac)
    assert r.status == "done"
    assert mac.looked[0] is None and all(a == "Calculator" for a in mac.looked[1:]) and len(mac.looked) >= 2


def test_not_in_front_twice_stops_politely():
    refused = {"ok": False, "error": "Calculator isn't in front (another app is in use), so I won't type"}
    mac = FakeMac(act_results=[refused, refused])
    decide = _decider(*[Move({"action": "key", "keys": "return"}, 0.9, "decision", 1)] * 3)
    r = L.run("g", [{"do": "x"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "stuck" and "in front" in r.reason and len(mac.acts) == 2


def test_fallback_can_open_an_app():
    from agent.computer.decide import _valid
    assert _valid({"action": "open_app", "app": "Notes"}, {"elements": []}, {}) == {"action": "open_app",
                                                                                  "app": "Notes"}
    assert _valid({"action": "open_app"}, {"elements": []}, {}) == {"action": "stuck"}
