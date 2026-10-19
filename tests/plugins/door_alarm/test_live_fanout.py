"""Live buttons follow the door alarm: on every state change (not every hub report) the phone hears
``live_state``, the Control Center tiles get a refresh push and the Lock Screen card / Dynamic Island
gets a Live Activity update, end or push-to-start — best effort, off the alarm lock."""
import threading

import pytest

from plugins.door_alarm import live_buttons
from plugins.door_alarm.service import DoorService
from plugins.door_alarm.store import DoorStore
from plugins.toyota.approver import Approvals

from .test_service import FakeApprover, FakeBridge, FakeCloud, FakePush

APPLE_EPOCH = 978307200   # 2001-01-01T00:00:00Z: where Swift's default JSONDecoder counts Dates from


class LiveBridge(FakeBridge):
    def __init__(self, log):
        super().__init__()
        self.log = log
        self.offers["live_state"] = "phone1"
        self.live_fail = False

    def offering_all(self, skill):
        return ["phone1", "phone2"] if skill == "live_state" else []

    def invoke(self, device, skill, args, timeout=10.0):
        if skill == "live_state":
            self.log.append(("live_state", device, args))
            if self.live_fail:
                raise RuntimeError("phone asleep")
        return super().invoke(device, skill, args, timeout)


class FakeLive:
    def __init__(self, log):
        self.log = log
        self.card = False       # a door card is running on the phone (its token is stored)
        self.start_token = True  # the phone wants door cards started for it
        self.fail = False
        self.lock_free = []     # whether the alarm lock was free at each call
        self.contents = []      # every content-state pushed, never cleared
        self.svc = None

    def _note(self, *entry):
        if self.svc is not None:
            holder = {}

            def probe():   # from another thread: is the alarm lock free right now?
                holder["ok"] = self.svc.lock.acquire(blocking=False)
                if holder["ok"]:
                    self.svc.lock.release()

            t = threading.Thread(target=probe)
            t.start()
            t.join()
            self.lock_free.append(bool(holder.get("ok")))
        self.log.append(entry)
        if self.fail:
            raise RuntimeError("APNs down")

    def activity(self, source, content_state, event="update", **kw):
        self.contents.append(content_state)
        self._note("activity", source, event, content_state, kw)
        return 1 if self.card else 0

    def start(self, source, content_state, **kw):
        self.contents.append(content_state)
        self._note("start", source, content_state, kw)
        return 1

    def needs_start(self, source):
        return self.start_token and not self.card

    def forget_stale(self, source, before):
        self._note("forget_stale", source, before)

    def refresh_controls(self):
        self._note("controls")
        return 1


@pytest.fixture
def env(tmp_path):
    clock = [1_800_000_000.0]
    log = []
    bridge, live = LiveBridge(log), FakeLive(log)
    queued = []
    svc = DoorService(store=DoorStore(tmp_path), clock=lambda: clock[0], bridge=bridge, push=FakePush(),
                      cloud=lambda: FakeCloud(), approver=FakeApprover(), approvals=Approvals(clock=lambda: clock[0]),
                      run_prompt=lambda p: None, run=lambda fn: fn(), live=live, live_run=queued.append,
                      live_grace=0, confirm_timeout=0.2)
    bridge.service = svc
    live.svc = svc
    svc.pick("hub1")
    svc.set_proxy("board1")
    svc.update_settings({"alarm": {"exit_delay": 60, "entry_delay": 30, "siren_duration": 180}})

    def flush():
        while queued:
            queued.pop(0)()

    flush()
    log.clear()
    return svc, clock, bridge, live, log, flush


def door(svc, open_):
    svc.on_board_event("board1", "door_report", {"dps": {"1": open_}, "t": 0, "seq": 2})


def kinds(log):
    return [e[0] for e in log]


def cards(log):
    return [e for e in log if e[0] in ("activity", "start")]


# ── the pure view ──

def test_dates_are_seconds_since_2001_like_swifts_default_json_decoder():
    # JSONDecoder's default .deferredToDate reads a Date as a Double of seconds since 2001-01-01 UTC.
    assert live_buttons.apple_date(APPLE_EPOCH) == 0
    assert live_buttons.apple_date(APPLE_EPOCH + 90.5) == 90.5
    assert live_buttons.apple_date(1_800_000_060) == 1_800_000_060 - 978307200
    assert live_buttons.apple_date(None) is None


def test_arming_reads_stop_arming_with_the_countdown():
    alarm = {"state": "arming", "mode": "away", "deadline": 1_800_000_060.0, "since": 1_800_000_000.0,
             "siren_on": False, "contact_name": None}
    s = live_buttons.button_state(alarm)
    assert s == {"id": "door.arming", "title": "Stop arming", "symbol": "stop.circle.fill", "caption": "Away in",
                 "alert": False, "startedAt": 1_800_000_000 - APPLE_EPOCH, "endsAt": 1_800_000_060 - APPLE_EPOCH}
    assert live_buttons.button_state({**alarm, "mode": "home"})["caption"] == "Home in"


def test_every_state_has_the_swift_keys():
    required = {"id", "title", "symbol", "alert"}
    allowed = required | {"caption", "tint", "startedAt", "endsAt"}
    for state in ("disarmed", "arming", "armed_away", "armed_home", "entry", "triggered"):
        for siren in (False, True):
            s = live_buttons.button_state({"state": state, "mode": "away", "deadline": 1.0, "since": 0.0,
                                           "siren_on": siren, "contact_name": "Front Door", "triggered_at": 0.0})
            assert required <= set(s) <= allowed, state
            assert isinstance(s["alert"], bool)


REQUIRED_STATE = {"id": str, "title": str, "symbol": str, "alert": bool}   # non-optional in ButtonLiveState
OPTIONAL_STATE = {"caption", "tint", "startedAt", "endsAt"}


def assert_decodes(cs):
    """What ButtonActivityAttributes.ContentState needs from a plain JSONDecoder: `finished` (Bool) at
    the top, every non-optional ButtonLiveState key in `state`; optionals may be absent; dates are
    Doubles (seconds since 2001)."""
    assert isinstance(cs.get("finished"), bool)
    assert set(cs) <= {"state", "finished", "result"}
    assert cs.get("result") is None or isinstance(cs["result"], str)
    state = cs["state"]
    for k, kind in REQUIRED_STATE.items():
        assert isinstance(state.get(k), kind), k
    assert set(state) <= set(REQUIRED_STATE) | OPTIONAL_STATE
    for k in ("startedAt", "endsAt"):
        assert state.get(k) is None or isinstance(state[k], float), k


def test_content_has_every_key_the_swift_decoder_needs():
    for alarm_state in ("disarmed", "arming", "armed_away", "armed_home", "entry", "triggered"):
        s = live_buttons.button_state({"state": alarm_state, "mode": "away", "deadline": 1_800_000_060.0,
                                       "since": 1_800_000_000.0, "siren_on": False, "contact_name": None})
        assert_decodes(live_buttons.content(s))
        assert_decodes(live_buttons.content(s, finished=True, result="Armed Away"))
    assert live_buttons.content(s)["finished"] is False   # sent even when false


def test_entry_and_triggered_are_alerts():
    base = {"mode": "away", "deadline": 1.0, "since": 0.0, "contact_name": "Front Door", "triggered_at": 0.0}
    entry = live_buttons.button_state({**base, "state": "entry", "siren_on": False})
    assert (entry["title"], entry["caption"], entry["alert"]) == ("Disarm", "Front Door opened", True)
    loud = live_buttons.button_state({**base, "state": "triggered", "siren_on": True})
    quiet = live_buttons.button_state({**base, "state": "triggered", "siren_on": False})
    assert loud["title"] == "Silence" and loud["alert"]
    assert quiet["title"] == "Disarm" and quiet["alert"]


# ── the fan-out ──

def test_arming_tells_the_phones_refreshes_the_tiles_and_starts_the_card(env):
    svc, clock, bridge, live, log, flush = env
    svc.arm("away")
    assert log == []            # nothing under the command: the work is queued
    flush()
    alarm = svc.state()["alarm"]
    invokes = [e for e in log if e[0] == "live_state"]
    assert [e[1] for e in invokes] == ["phone1", "phone2"]
    assert invokes[0][2] == {"source": "door", "alarm": alarm}
    assert kinds(log).count("controls") == 1
    start = [e for e in log if e[0] == "start"]
    assert len(start) == 1
    _, source, content, kw = start[0]
    assert source == "door"
    assert content == {"state": live_buttons.button_state(alarm), "finished": False}
    assert content["state"]["endsAt"] == alarm["deadline"] - APPLE_EPOCH
    assert kw["attributes_type"] == "ButtonActivityAttributes"
    assert kw["attributes"] == {"source": "door", "buttonID": "", "name": "Door alarm", "symbol": "lock.shield"}
    assert kw["alert"]["title"] == "Door alarm" and kw["alert"]["body"] == "Arming Away"
    # the phone had its chance to start its own card first
    assert kinds(log).index("start") > max(i for i, e in enumerate(log) if e[0] == "live_state")
    assert all(live.lock_free)


def test_a_running_card_gets_updates_not_a_second_start(env):
    svc, clock, bridge, live, log, flush = env
    live.card = True
    svc.arm("away")
    flush()
    assert "start" not in kinds(log)
    act = [e for e in log if e[0] == "activity"]
    assert len(act) == 1 and act[0][2] == "update"
    assert act[0][3]["finished"] is False and act[0][3]["state"]["title"] == "Stop arming"


def test_no_start_when_the_phone_does_not_want_door_cards(env):
    svc, clock, bridge, live, log, flush = env
    live.start_token = False
    svc.arm("away")
    flush()
    assert "start" not in kinds(log)


def test_a_new_episode_forgets_a_card_token_left_from_before(env):
    svc, clock, bridge, live, log, flush = env
    svc.arm("away")
    flush()
    stale = [e for e in log if e[0] == "forget_stale"]
    assert stale and stale[0][1] == "door" and stale[0][2] < clock[0]


def test_the_exit_delay_ending_ends_the_card_with_armed_away(env):
    svc, clock, bridge, live, log, flush = env
    live.card = True
    svc.arm("away")
    flush()
    shown = svc.state()["alarm"]
    log.clear()
    clock[0] += 60
    svc.tick()
    flush()
    assert svc.alarm.state == "armed_away"
    act = [e for e in log if e[0] == "activity"]
    assert len(act) == 1 and act[0][2] == "end"
    content = act[0][3]
    assert content["finished"] is True and content["result"] == "Armed Away"
    assert content["state"] == live_buttons.button_state(shown)   # the last state the card showed
    assert act[0][4].get("dismissal_after") is not None
    assert [e[2]["alarm"]["state"] for e in log if e[0] == "live_state"] == ["armed_away", "armed_away"]
    assert kinds(log).count("controls") == 1
    assert "start" not in kinds(log)


def test_cancelling_ends_the_card_with_arming_cancelled(env):
    svc, clock, bridge, live, log, flush = env
    live.card = True
    svc.arm("away")
    flush()
    log.clear()
    svc.cancel_arming()
    flush()
    act = [e for e in log if e[0] == "activity"]
    assert act[0][2] == "end" and act[0][3]["result"] == "Arming cancelled"


def test_arm_home_has_no_card_but_the_tiles_and_phone_hear(env):
    svc, clock, bridge, live, log, flush = env
    svc.arm("home")
    flush()
    assert svc.alarm.state == "armed_home"
    assert cards(log) == []
    assert kinds(log).count("controls") == 1 and kinds(log).count("live_state") == 2


def test_entry_then_alarm_then_silence_then_disarm(env):
    svc, clock, bridge, live, log, flush = env
    svc.arm("home")
    flush()
    log.clear()
    door(svc, True)
    flush()
    assert svc.alarm.state == "entry"
    start = [e for e in log if e[0] == "start"]
    assert len(start) == 1 and start[0][2]["state"]["title"] == "Disarm"
    assert start[0][2]["state"]["caption"] == "Front Door opened" and start[0][2]["state"]["alert"] is True
    live.card = True       # the phone reported the started card's token
    log.clear()
    clock[0] += 30
    svc.tick()
    flush()
    assert svc.alarm.state == "triggered"
    act = [e for e in log if e[0] == "activity"]
    assert len(act) == 1 and act[0][2] == "update" and act[0][3]["state"]["title"] == "Silence"
    assert "start" not in kinds(log)     # still the same episode: never a second card
    log.clear()
    svc.silence({"nonce": "n1", "ts": 1, "signature": "good"})
    flush()
    act = [e for e in log if e[0] == "activity"]
    assert len(act) == 1 and act[0][3]["state"]["title"] == "Disarm"   # siren off: no state change, still told
    log.clear()
    svc.disarm({"nonce": "n2", "ts": 1, "signature": "good"})
    flush()
    act = [e for e in log if e[0] == "activity"]
    assert act[0][2] == "end" and act[0][3]["result"] == "Disarmed" and act[0][3]["finished"] is True
    assert kinds(log).count("controls") == 1
    assert len(live.contents) == 5
    for cs in live.contents:          # entry update (no card yet) + start, Silence, Disarm, end
        assert_decodes(cs)


def test_hub_reports_that_change_nothing_send_nothing(env):
    svc, clock, bridge, live, log, flush = env
    svc.arm("home")
    flush()
    log.clear()
    for _ in range(3):
        svc.refresh_values()                   # a status read: same values
        svc.on_board_event("board1", "door_report", {"dps": {"1": False}, "t": 0, "seq": 3})
        svc.tick()
    flush()
    assert log == []


def test_failures_never_break_the_alarm(env):
    svc, clock, bridge, live, log, flush = env
    live.fail = True
    bridge.live_fail = True
    svc.arm("away")
    flush()                                   # every step raised: logged, the rest still ran
    assert kinds(log).count("live_state") == 2 and "controls" in kinds(log)
    assert svc.alarm.state == "arming"
    clock[0] += 60
    svc.tick()
    flush()
    assert svc.alarm.state == "armed_away"
    assert svc.store.state()["state"] == "armed_away"


def test_a_change_queued_behind_a_newer_one_does_not_start_a_stale_card(env):
    svc, clock, bridge, live, log, flush = env
    svc.arm("away")
    svc.cancel_arming()       # before the first job ran
    flush()
    assert "start" not in kinds(log)


def test_a_restart_mid_arming_still_ends_the_card(tmp_path, env):
    svc, clock, bridge, live, log, flush = env
    live.card = True
    svc.arm("away")
    flush()
    log.clear()
    queued = []
    again = DoorService(store=svc.store, clock=lambda: clock[0], bridge=bridge, push=FakePush(),
                        cloud=lambda: FakeCloud(), approver=FakeApprover(), approvals=Approvals(clock=lambda: clock[0]),
                        run_prompt=lambda p: None, run=lambda fn: fn(), live=live, live_run=queued.append,
                        live_grace=0, confirm_timeout=0.2)
    clock[0] += 60
    again.tick()
    while queued:
        queued.pop(0)()
    act = [e for e in log if e[0] == "activity"]
    assert act and act[0][2] == "end" and act[0][3]["result"] == "Armed Away"
    assert act[0][3]["state"]["title"] == "Stop arming"


def test_live_state_is_server_only():
    from webui.api.device_bridge import SERVER_ONLY_SKILLS
    assert "live_state" in SERVER_ONLY_SKILLS
