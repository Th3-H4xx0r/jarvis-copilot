"""Keep-awake policy, quiet timer check-ins and Wake Mac (jc_client/mac_power.py)."""
from __future__ import annotations

from jc_client.mac_power import CHECKIN, GRACE, KEEP_AWAKE_MAX, REMOTE_IDLE, MacPower, should_hold

FULL = (80, True)


def hold(now=1000.0, sessions=(), manual=False, remote_since=None, last_busy=None,
         pending_password=False, battery=FULL):
    return should_hold(now, list(sessions), manual=manual, remote_since=remote_since,
                       last_busy=last_busy, pending_password=pending_password, battery=battery)


def test_busy_states_hold():
    for state in ("thinking", "working", "approval", "question", "ratelimit"):
        assert hold(sessions=[{"state": state}]) == (True, "session")
    assert hold(sessions=[{"state": "idle"}, {"state": "finished"}]) == (False, "")


def test_grace_600s_after_last_busy():
    assert GRACE == 600.0
    assert hold(now=1000 + 599, last_busy=1000) == (True, "grace")
    assert hold(now=1000 + 601, last_busy=1000) == (False, "")


def test_pending_password_holds():
    assert hold(pending_password=True) == (True, "password")


def test_manual_holds():
    assert hold(manual=True) == (True, "manual")


def test_remote_wake_releases_after_1800s_idle():
    assert REMOTE_IDLE == 1800.0
    assert hold(now=1000 + 1799, remote_since=1000) == (True, "remote")
    assert hold(now=1000 + 1801, remote_since=1000) == (False, "")
    # a session that worked after the wake restarts the idle count
    assert hold(now=1000 + 2500, remote_since=1000, last_busy=1000 + 1000) == (True, "remote")


def test_battery_5_percent_releases():
    assert hold(sessions=[{"state": "working"}], manual=True, battery=(5, False)) == (False, "")
    assert hold(sessions=[{"state": "working"}], battery=(6, False)) == (True, "session")
    assert hold(sessions=[{"state": "working"}], battery=(3, True)) == (True, "session")   # charging


# ── MacPower ─────────────────────────────────────────────────────────────────
class FakeHelper:
    def __init__(self):
        self.calls = []
        self.reply = {"ok": True}

    def call(self, op, **kw):
        self.calls.append((op, kw))
        return dict(self.reply)


class Rig:
    def __init__(self, *, reason="lid", checkin=None, lid="open", battery=FULL, sessions=()):
        self.t = 100_000.0
        self.idle = 1e9           # nobody at the Mac
        self.during_checkin = None
        self.helper = FakeHelper()
        self.up = []
        self.reason = reason
        self.checkin_answer = checkin
        self.checkins = 0
        self.lid_state = lid
        self.sessions = list(sessions)
        self.power = MacPower(self.helper.call, self.up.append, self._checkin, lambda: self.sessions,
                              battery=lambda: battery, wake_reason=lambda: self.reason,
                              lid=lambda: self.lid_state, idle=lambda: self.idle,
                              clock=lambda: self.t, mono=lambda: self.t)

    def _checkin(self):
        self.checkins += 1
        if self.during_checkin:
            self.during_checkin(self)
        if isinstance(self.checkin_answer, Exception):
            raise self.checkin_answer
        return self.checkin_answer

    def ops(self):
        return [op for op, _ in self.helper.calls]


def test_will_sleep_schedules_900s_when_timer_on():
    rig = Rig()
    assert rig.power.on_will_sleep() is True                     # first sleep is announced
    assert ("wake_at", {"ts": rig.t + CHECKIN}) in rig.helper.calls
    assert CHECKIN == 900.0
    rig2 = Rig()
    rig2.power.on_frame({"type": "mac_power_set", "timer_on": False})
    rig2.power.on_will_sleep()
    assert "wake_at" not in rig2.ops()


def test_rtc_wake_with_nothing_pending_sleeps_quietly():
    rig = Rig(reason="rtc/Alarm", checkin={"wake": False, "keep_awake": False, "timer_on": True})
    rig.power.on_will_sleep()
    rig.t += CHECKIN
    rig.helper.calls.clear()
    assert rig.power.on_did_wake() is False                       # no hello
    assert rig.power.quiet() is True                              # no reconnect either
    assert rig.ops() == ["wake_at", "sleepnow"]                   # next check-in armed first
    assert rig.power.on_will_sleep() is False                     # the re-sleep isn't announced


def test_rtc_wake_with_request_is_real():
    rig = Rig(reason="rtc/Alarm", checkin={"wake": True, "keep_awake": False, "timer_on": True})
    rig.power.on_will_sleep()
    rig.t += CHECKIN
    assert rig.power.on_did_wake() is True
    assert rig.power.quiet() is False
    rig.power.tick()
    assert rig.power.status()["reason"] == "remote"
    assert ("hold", {"on": True}) in rig.helper.calls


def test_user_wake_is_real_and_cancels_timer():
    rig = Rig(reason="lid SMC.OutboxNotEmpty RTP.multi-touch")
    rig.power.on_will_sleep()
    rig.t += 120
    assert rig.power.on_did_wake() is True
    assert rig.checkins == 0
    assert "cancel_wake" in rig.ops()


def test_other_rtc_wake_far_from_our_alarm_is_real():
    rig = Rig(reason="rtc/SleepService")
    rig.power.on_will_sleep()
    rig.t += 300                                                  # not our 900 s alarm
    assert rig.power.on_did_wake() is True
    assert rig.checkins == 0


def test_checkin_http_failure_is_real_wake():
    rig = Rig(reason="rtc/Alarm", checkin=OSError("offline"))
    rig.power.on_will_sleep()
    rig.t += CHECKIN
    assert rig.power.on_did_wake() is True
    assert "sleepnow" not in rig.ops()


def test_push_wake_holds_as_remote():
    rig = Rig()
    rig.power.request_wake()
    rig.power.tick()
    assert rig.power.status()["reason"] == "remote"


def test_let_sleep_clears_remote_and_manual():
    rig = Rig(lid="closed")
    rig.power.request_wake()
    rig.power.on_frame({"type": "mac_power_set", "keep_awake": True})
    rig.power.tick()
    assert rig.power.status()["held"] is True
    rig.helper.calls.clear()
    rig.power.on_frame({"type": "mac_power_set", "let_sleep": True})
    assert rig.power.status()["held"] is False
    assert rig.ops() == ["hold", "sleepnow"]                       # lid shut: sleep now


def test_release_with_lid_open_does_not_force_sleep():
    rig = Rig(lid="open", sessions=[{"state": "working"}])
    rig.power.tick()
    rig.sessions = []
    rig.t += GRACE + 1
    rig.helper.calls.clear()
    rig.power.tick()
    assert rig.ops() == ["hold"]


def test_held_tick_sends_heartbeat_and_status_up():
    rig = Rig(sessions=[{"state": "working"}])
    rig.power.tick()
    rig.power.tick()
    assert rig.ops().count("heartbeat") >= 1
    status = [f for f in rig.up if f.get("name") == "mac_power_status"]
    assert status and status[-1]["data"]["held"] is True
    assert status[-1]["data"]["reason"] == "session"



def checkin_rig(answer=None, **kw):
    rig = Rig(reason="rtc/Alarm", checkin=answer or {"wake": False, "keep_awake": False, "timer_on": True}, **kw)
    rig.power.on_will_sleep()
    rig.t += CHECKIN
    return rig


def test_second_wake_signal_during_a_checkin_stays_quiet():
    seen = {}
    rig = checkin_rig()
    rig.during_checkin = lambda r: seen.update(second=r.power.on_did_wake())   # the clock-jump signal
    assert rig.power.on_did_wake() is False
    assert seen["second"] is False


def test_he_opens_the_lid_during_a_checkin_so_it_is_real():
    seen = {}
    rig = checkin_rig(lid="closed")

    def opens(r):
        r.lid_state = "open"
        seen["second"] = r.power.on_did_wake()
    rig.during_checkin = opens
    assert rig.power.on_did_wake() is True
    assert seen["second"] is True
    assert "sleepnow" not in rig.ops()


def test_typing_during_a_checkin_keeps_it_awake():
    rig = checkin_rig()
    rig.during_checkin = lambda r: setattr(r, "idle", 0.2)
    assert rig.power.on_did_wake() is True
    assert "sleepnow" not in rig.ops()


def test_push_during_a_checkin_wins():
    rig = checkin_rig()
    rig.during_checkin = lambda r: r.power.request_wake()
    assert rig.power.on_did_wake() is True
    assert "sleepnow" not in rig.ops()


def test_keep_awake_on_low_battery_checkin_stays_quiet():
    rig = checkin_rig({"wake": False, "keep_awake": True, "timer_on": True}, battery=(4, False))
    assert rig.power.on_did_wake() is False


def test_no_status_during_a_checkin():
    rig = checkin_rig()
    rig.up.clear()
    rig.power.on_did_wake()
    rig.power.tick()
    assert not [f for f in rig.up if f.get("name") == "mac_power_status"]


def test_held_only_when_the_helper_confirms():
    rig = Rig(sessions=[{"state": "working"}])
    rig.helper.reply = {"ok": False, "error": "not installed"}
    rig.power.tick()
    assert rig.power.status()["held"] is False
    rig.helper.reply = {"ok": True}
    rig.power.tick()
    assert rig.power.status()["held"] is True


def test_helper_that_restarted_is_told_to_hold_again():
    rig = Rig(sessions=[{"state": "working"}])
    rig.power.tick()
    rig.helper.reply = {"ok": True, "held": False}
    rig.helper.calls.clear()
    rig.power.tick()
    assert rig.ops() == ["heartbeat", "hold"]


def test_keep_awake_turns_itself_off_after_12h():
    rig = Rig()
    rig.power.on_frame({"type": "mac_power_set", "keep_awake": True})
    rig.t += KEEP_AWAKE_MAX - 1
    rig.power.tick()
    assert rig.power.status()["keep_awake"] is True
    rig.t += 2
    rig.power.tick()
    assert rig.power.status()["keep_awake"] is False
    assert {"type": "event", "name": "mac_power_set", "data": {"keep_awake": False}} in rig.up
    assert KEEP_AWAKE_MAX == 12 * 3600.0


def test_a_checkin_that_never_slept_stops_hiding_after_a_minute():
    rig = checkin_rig()
    rig.power.on_did_wake()
    assert rig.power.quiet() is True
    rig.t += 61
    rig.power.tick()
    assert rig.power.quiet() is False
