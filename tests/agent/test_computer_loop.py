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
                      Move({"action": "done"}, 0.95, "decision", 10))
    r = L.run("work out 7", [{"do": "open Calculator", "app": "Calculator"}, {"do": "enter seven"}], _cfg(),
              device="mac1", progress=lines.append, decide=decide, fallback=_never, mac=mac)
    assert r.status == "done"
    assert mac.acts[0][0] == {"action": "open_app", "app": "Calculator"}
    assert mac.acts[1][0] == {"action": "click", "element": 1}
    assert len(r.actions) == 2 and len(lines) == 2
    assert "button '7'" in lines[1]
    assert decide.calls == ["enter seven", "enter seven"]  # opening the app needed no decision


def test_loop_low_conf_uses_fallback():
    mac = FakeMac()
    used = []

    def fallback(ref, look, goal, step, history, **kw):
        used.append(ref)
        return Move({"action": "click", "element": 2}, None, "fallback", 50)

    decide = _decider(Move({"action": "click", "element": 1}, 0.3, "decision", 10))
    r = L.run("g", [{"do": "get the result"}], _cfg(), device="m", decide=decide, fallback=fallback, mac=mac)
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
    r = L.run("g", [{"do": "clear the display", "app": "Calculator"}], _cfg(), device="m", decide=decide,
              fallback=_never, mac=mac)
    assert r.status == "done"
    # No first look (the step opens Calculator); every later look reads Calculator.
    assert mac.looked and all(a == "Calculator" for a in mac.looked)


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


def test_steps_naming_a_button_click_it_without_a_decision():
    mac = FakeMac()
    r = L.run("12×7", [{"do": "click 7 button"}, {"do": "press ="}], _cfg(), device="m",
              decide=_decider(Move({"action": "click", "element": 2}, 0.9, "decision", 1),
                              Move({"action": "done"}, 0.9, "decision", 1)),
              fallback=_never, mac=mac)
    assert r.status == "done"
    assert mac.acts[0][0] == {"action": "click", "element": 1} and r.actions[0]["by"] == "match"


def test_run_starts_on_the_named_app():
    mac = AppMac()
    r = L.run("g", [{"do": "click 7 button"}], _cfg(), device="m", app="Calculator",
              decide=_decider(), fallback=_never, mac=mac)
    assert mac.looked[0] == "Calculator" and r.status == "done"


def test_done_before_any_move_on_a_step_needs_the_fallback():
    """The decider called "click ×" done before pressing it; that needs a second opinion."""
    mac = FakeMac()
    asked = []

    def fallback(ref, look, goal, step, history, **kw):
        asked.append(step["do"])
        return Move({"action": "click", "element": 2}, None, "fallback", 5)

    decide = _decider(Move({"action": "done"}, 0.8, "decision", 1), Move({"action": "done"}, 0.9, "decision", 1))
    r = L.run("12x7", [{"do": "press the times key"}], _cfg(), device="m", decide=decide, fallback=fallback, mac=mac)
    assert asked == ["press the times key"] and mac.acts[0][0] == {"action": "click", "element": 2}
    assert r.status == "done"


def test_a_failed_look_after_opening_is_retried_then_reported():
    """Demo: a cold-launched app's first looks failed and the deciders ran on nothing."""
    class SlowMac(FakeMac):
        def __init__(self):
            super().__init__()
            self.fails = 2

        def look(self, device, app=None):
            if app and self.fails:
                self.fails -= 1
                return {"ok": False, "error": "Calculator has no open window."}
            return super().look(device, app)

        def act(self, device, action, look_id):
            self.acts.append((action, look_id))
            return {"ok": True, "did": action["action"], "via": "app", "look": {"ok": False, "error": "no window"}}

    mac = SlowMac()
    r = L.run("g", [{"do": "clear it", "app": "Calculator"}], _cfg(), device="m",
              decide=_decider(Move({"action": "done"}, 0.9, "decision", 1)), fallback=_never, mac=mac)
    assert r.status == "done" and mac.fails == 0

    mac = SlowMac()
    mac.fails = 99
    r = L.run("g", [{"do": "clear it", "app": "Calculator"}], _cfg(), device="m", decide=_never, fallback=_never,
              mac=mac)
    assert r.status == "error" and "no open window" in r.reason


def test_planned_web_task_opens_the_page_directly_without_a_first_look():
    """Speed: plan from his words (no screenshot), then open the results page in one step."""
    mac = AppMac()
    order = []

    def plan(ref, goal, look, **kw):
        order.append(("plan", look))
        return {"steps": [{"do": "open the Amazon results for computer", "app": "Safari",
                           "url": "https://www.amazon.com/s?k=computer"},
                          {"do": "click the first product result"}]}

    r = L.run("on my mac search amazon for computer and open the first result", None, _cfg(), device="m",
              decide=_decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1),
                              Move({"action": "done"}, 0.9, "decision", 1)),
              fallback=_never, mac=mac, plan=plan)
    assert order == [("plan", None)] and mac.looked == []
    assert mac.acts[0][0] == {"action": "open_url", "url": "https://www.amazon.com/s?k=computer", "app": "Safari"}
    assert mac.acts[1][0] == {"action": "click", "element": 1} and r.status == "done"


def test_click_on_a_text_field_fills_it_or_finishes_the_step():
    look = {"ok": True, "look_id": "L1", "app": "Safari", "sig": "a",
            "elements": [{"i": 1, "role": "AXTextField", "label": "smart search field"}]}

    class FieldMac(FakeMac):
        def look(self, device, app=None):
            return dict(look)

        def act(self, device, action, look_id):
            self.acts.append((action, look_id))
            return {"ok": True, "did": action["action"], "via": "ax", "look": dict(look)}

    mac = FieldMac()
    r = L.run("g", [{"do": "put amazon.com in the address bar", "text": "amazon.com"}], _cfg(), device="m",
              decide=_decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1),
                              Move({"action": "done"}, 0.9, "decision", 1)), fallback=_never, mac=mac)
    assert mac.acts[0][0] == {"action": "fill", "element": 1, "text": "amazon.com"} and r.status == "done"

    mac = FieldMac()
    r = L.run("g", [{"do": "focus the address bar"}], _cfg(), device="m",
              decide=_decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1)), fallback=_never, mac=mac)
    assert len(mac.acts) == 1 and r.status == "done"


def test_stop_is_checked_right_before_a_move():
    mac = FakeMac()
    stop = {"now": False}

    def decide(*a, **k):
        stop["now"] = True  # he says stop while the move is being decided
        return Move({"action": "click", "element": 1}, 0.9, "decision", 1)

    r = L.run("g", [{"do": "enter seven"}], _cfg(), device="m", should_stop=lambda: stop["now"],
              decide=decide, fallback=_never, mac=mac)
    assert r.status == "error" and r.reason == "stopped" and mac.acts == []


def test_open_only_means_just_opening_the_app():
    assert L._open_only({"do": "open Spotify", "app": "Spotify"})
    assert L._open_only({"do": "Launch the Calculator app", "app": "Calculator"})
    assert not L._open_only({"do": "Go to the Library tab", "app": "Spotify"})
    assert not L._open_only({"do": "open Spotify and play lo-fi", "app": "Spotify"})


def test_a_one_move_step_ends_with_its_move():
    """Speed: "click the first result" needs no extra "is it done?" decision."""
    mac = FakeMac()
    decide = _decider(Move({"action": "click", "element": 2}, 0.9, "decision", 1))
    r = L.run("g", [{"do": "click the first result"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "done" and len(decide.calls) == 1 and len(mac.acts) == 1


def test_he_is_using_the_mac_twice_stops_politely():
    busy = {"ok": False, "error": "You're using the Mac right now, so I won't type or move the cursor"}
    mac = FakeMac(act_results=[busy, busy])
    decide = _decider(*[Move({"action": "key", "keys": "return"}, 0.9, "decision", 1)] * 3)
    r = L.run("g", [{"do": "x"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert r.status == "stuck" and "using the Mac" in r.reason


def test_going_in_circles_between_two_screens_stops():
    """Live (his voice, Amazon): Go back ↔ open the same product, six times over."""
    screens = {"results": {"ok": True, "look_id": "R", "app": "Safari", "sig": "results",
                           "elements": [{"i": 1, "role": "AXLink", "label": "Gaming PC"}]},
               "product": {"ok": True, "look_id": "P", "app": "Safari", "sig": "product",
                           "elements": [{"i": 1, "role": "AXButton", "label": "Go back"}]}}

    class TwoScreens(FakeMac):
        def __init__(self):
            super().__init__()
            self.at = "results"

        def look(self, device, app=None):
            return dict(screens[self.at])

        def act(self, device, action, look_id):
            self.acts.append((action, look_id))
            self.at = "product" if self.at == "results" else "results"
            return {"ok": True, "did": "click", "via": "ax", "look": dict(screens[self.at])}

    mac = TwoScreens()
    decide = _decider(*[Move({"action": "click", "element": 1}, 0.9, "decision", 1)] * 20)
    r = L.run("g", [{"do": "make sure the first result is showing"}], _cfg(), device="m", decide=decide,
              fallback=_never, mac=mac)
    assert r.status == "stuck" and "circles" in r.reason and len(mac.acts) <= 5


def test_deciders_see_the_step_list_with_progress():
    from agent.computer.decide import context
    text = context({"elements": []}, "g", {"do": "open the first result"}, [],
                   plan=[{"do": "search for pc"}, {"do": "open the first result"}], at=1)
    assert "1) ✓ search for pc" in text and "2) ▶ open the first result" in text


def test_a_wait_does_not_finish_a_one_move_step():
    """Live (YouTube): the page was loading, the decider waited, and "click the first video" counted as done."""
    mac = FakeMac()
    decide = _decider(Move({"action": "wait"}, 0.7, "decision", 1), Move({"action": "click", "element": 2}, 0.9, "decision", 1))
    r = L.run("g", [{"do": "click the first video"}], _cfg(), device="m", decide=decide, fallback=_never, mac=mac)
    assert [a[0]["action"] for a in mac.acts] == ["wait", "click"] and r.status == "done"


def test_a_read_step_carries_a_value_into_later_typing():
    """Live: "write the Amazon price in a note" typed a placeholder — the plan couldn't know the price."""
    look = {"ok": True, "look_id": "L1", "app": "Notes", "sig": "a",
            "elements": [{"i": 1, "role": "AXTextArea", "label": "note body"}]}

    class NoteMac(FakeMac):
        def look(self, device, app=None):
            return dict(look)

        def act(self, device, action, look_id):
            self.acts.append((action, look_id))
            return {"ok": True, "did": action["action"], "via": "ax", "look": dict(look)}

    mac = NoteMac()
    reads = []

    def read(ref, look_, goal, step, **kw):
        reads.append(step["read"])
        return "$449.99"

    decide = _decider(Move({"action": "fill", "element": 1, "text": "Switch 2: {price}"}, 0.9, "decision", 1),
                      Move({"action": "done"}, 0.9, "decision", 1))
    r = L.run("g", [{"do": "read the price of the first result", "read": "price"},
                    {"do": "type the price into the note", "text": "Switch 2: {price}"}], _cfg(), device="m",
              decide=decide, fallback=_never, mac=mac, read=read)
    assert reads == ["price"] and r.values == {"price": "$449.99"}
    assert mac.acts[0][0] == {"action": "fill", "element": 1, "text": "Switch 2: $449.99"}


def test_an_unreadable_value_stops_instead_of_typing_a_placeholder():
    mac = FakeMac()
    nowhere = lambda *a, **k: Move({"action": "stuck"}, 0.9, "decision", 1, why="not found")  # noqa: E731
    r = L.run("g", [{"do": "read the price", "read": "price"}, {"do": "type it", "text": "{price}"}], _cfg(),
              device="m", decide=nowhere, fallback=nowhere, mac=mac, read=lambda *a, **k: "")
    assert r.status == "stuck" and "price" in r.reason and mac.acts == []


def test_a_step_on_the_app_already_in_use_does_not_reopen_it():
    mac = AppMac(act_results=[None])
    decide = _decider(Move({"action": "click", "element": 1}, 0.9, "decision", 1),
                      Move({"action": "done"}, 0.9, "decision", 1))
    L.run("g", [{"do": "open Notes", "app": "Notes"}, {"do": "write in the note body", "app": "Notes"}], _cfg(),
          device="m", decide=decide, fallback=_never, mac=mac)
    assert [a[0]["action"] for a in mac.acts].count("open_app") == 1


def test_tell_steps_are_skipped():
    mac = FakeMac()
    r = L.run("g", [{"do": "tell the user her birth date: {born}"}], _cfg(), device="m", decide=_never,
              fallback=_never, mac=mac)
    assert r.status == "done" and mac.acts == []


def test_a_read_that_finds_nothing_navigates_then_reads_again():
    """Live (Calendar): "what's on tomorrow" read today's view; the next-day arrow was one click away."""
    mac = FakeMac()
    reads = iter(["", "Dentist 9am"])
    decide = _decider(Move({"action": "click", "element": 2}, 0.9, "decision", 1),
                      Move({"action": "done"}, 0.9, "decision", 1))
    r = L.run("what's on my calendar tomorrow", [{"do": "read tomorrow's events", "read": "events"}], _cfg(),
              device="m", decide=decide, fallback=_never, mac=mac, read=lambda *a, **k: next(reads))
    assert r.status == "done" and r.values == {"events": "Dentist 9am"} and len(mac.acts) == 1


def test_deciders_and_planner_know_today():
    from agent.computer.decide import context
    import datetime
    assert datetime.date.today().strftime("%B") in context({"elements": []}, "g", {"do": "x"}, [])


def test_a_just_opened_page_waits_for_its_text():
    class SlowPage(FakeMac):
        def __init__(self):
            super().__init__()
            self.calls = 0

        def look(self, device, app=None):
            self.calls += 1
            return {**_look(self.n), "text": "x" * (50 if self.calls < 3 else 900)}

        def act(self, device, action, look_id):
            self.acts.append((action, look_id))
            return {"ok": True, "did": action["action"], "via": "app", "look": {**_look(1), "text": ""}}

    mac = SlowPage()
    r = L.run("g", [{"do": "open results", "app": "Safari", "url": "https://example.com/s?q=x"},
                    {"do": "read the price", "read": "price"}], _cfg(), device="m", decide=_never, fallback=_never,
              mac=mac, read=lambda ref, look, goal, step, **k: "$1" if len(look.get("text", "")) > 400 else "")
    assert r.status == "done" and r.values == {"price": "$1"} and mac.calls >= 3


def test_a_step_that_types_a_web_address_opens_it_instead():
    """Live: Sonnet's step "type the URL into the address bar" filled Chrome's field but never loaded the page."""
    mac = AppMac()
    r = L.run("g", [{"do": "type the deals page URL into the address bar", "app": "Google Chrome",
                     "text": "https://www.macrumors.com/guide/airpods-deals/"}], _cfg(), device="m",
              decide=_never, fallback=_never, mac=mac)
    assert mac.acts[0][0] == {"action": "open_url", "url": "https://www.macrumors.com/guide/airpods-deals/",
                              "app": "Google Chrome"}
    assert r.status == "done" and len(mac.acts) == 1
