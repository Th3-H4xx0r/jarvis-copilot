"""The PC's 15-minute wake-timer check-in (his pick 2026-11-19, like the Mac's): long sleeps drop the PC off
Wi-Fi, so no magic packet reaches it; it wakes itself, asks the server, and sleeps again unless he wants it."""
from jc_client.pc_wake import CHECKIN, PcWake

T0 = 1_000_000.0


class Rig:
    def __init__(self, answer=None, idle=1e9):
        self.t = T0
        self.idle = idle
        self.answer = answer if answer is not None else {"wake": False, "timer_on": True}
        self.armed, self.cancels, self.suspends, self.checkins, self.displays, self.holds = [], 0, 0, 0, 0, []
        self.wake = PcWake(self._checkin, arm=self.armed.append, cancel=self._cancel, suspend=self._suspend,
                           idle_seconds=lambda: self.idle, display_on=self._display, hold=self.holds.append,
                           clock=lambda: self.t, retry_sleep=lambda s: None)

    def _checkin(self):
        self.checkins += 1
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer

    def _cancel(self):
        self.cancels += 1

    def _suspend(self):
        self.suspends += 1

    def _display(self):
        self.displays += 1

    def sleep_until_timer(self):
        self.wake.on_will_sleep()
        self.t = self.armed[-1]


def test_keeps_a_timer_armed_while_awake():
    rig = Rig()
    rig.wake.tick()
    assert rig.armed == [T0 + CHECKIN] and CHECKIN == 900.0
    rig.t += 30
    rig.wake.tick()                       # armed recently: left alone
    assert len(rig.armed) == 1
    rig.t += 60
    rig.wake.tick()                       # moved forward so a sleep any time finds it ≤15 min away
    assert rig.armed[-1] == rig.t + CHECKIN


def test_timer_wake_with_nothing_wanted_sleeps_again_quietly():
    rig = Rig()
    rig.sleep_until_timer()
    assert rig.wake.on_did_wake() is False          # no hello, no reconnect
    assert rig.checkins == 1 and rig.suspends == 1 and rig.armed[-1] == rig.t + CHECKIN
    assert rig.wake.on_will_sleep() is False         # the re-sleep isn't announced


def test_timer_wake_when_he_asked_turns_the_screen_on_and_stays():
    rig = Rig(answer={"wake": True, "timer_on": True})
    rig.sleep_until_timer()
    assert rig.wake.on_did_wake() is True and rig.suspends == 0
    assert rig.displays == 1 and rig.holds and not rig.wake.quiet()


def test_his_own_wake_is_real_and_never_checks_in():
    rig = Rig()
    rig.wake.on_will_sleep()
    rig.t += 300                                     # far from our timer: his hands or a magic packet
    assert rig.wake.on_did_wake() is True and rig.checkins == 0 and rig.suspends == 0


def test_someone_at_the_pc_during_a_timer_wake_keeps_it_up():
    rig = Rig(idle=5)
    rig.sleep_until_timer()
    assert rig.wake.on_did_wake() is True and rig.suspends == 0


def test_no_network_after_a_timer_wake_sleeps_again_to_retry_later():
    rig = Rig(answer=OSError("no route"))
    rig.sleep_until_timer()
    assert rig.wake.on_did_wake() is False and rig.suspends == 1 and rig.checkins >= 2


def test_timer_off_arms_nothing():
    rig = Rig()
    rig.wake.set_timer(False)
    rig.wake.tick()
    rig.wake.on_will_sleep()
    assert rig.armed == [] and rig.cancels >= 1


def test_a_resume_seen_twice_is_handled_once():
    rig = Rig()
    rig.sleep_until_timer()
    rig.wake.on_did_wake()
    rig.wake.on_did_wake()                           # the app's did_wake after the clock check saw it
    assert rig.checkins == 1 and rig.suspends == 1



def test_a_second_resume_signal_during_a_check_in_never_starts_another():
    # Review: two check-ins raced; the first got wake=True (cleared on the server) and was thrown away.
    rig = Rig(answer={"wake": True, "timer_on": True})
    seen = []
    def checkin():
        seen.append(1)
        if len(seen) == 1:
            rig.t += 25                                  # past the old 20 s dedupe window
            assert rig.wake.on_did_wake() is False       # the app's late did_wake: a check-in is in flight
        return rig.answer
    rig.wake._checkin = checkin
    rig.sleep_until_timer()
    assert rig.wake.on_did_wake() is True and len(seen) == 1 and rig.displays == 1


def test_a_wake_before_the_timer_fired_is_his():
    # Review: pressing power 90 s before the timer was taken for the timer and slept again.
    rig = Rig()
    fired = []
    rig.wake._fired = lambda: bool(fired)
    rig.wake.on_will_sleep()
    rig.t = rig.armed[-1] - 90
    assert rig.wake.on_did_wake() is True and rig.checkins == 0
    rig.sleep_until_timer()
    fired.append(1)
    assert rig.wake.on_did_wake() is False and rig.checkins == 1


def test_a_missed_resume_after_a_re_sleep_heals_itself():
    # Review: a resume the clock check missed left it "quiet" forever: no timer re-arms.
    rig = Rig()
    rig.sleep_until_timer()
    rig.wake.on_did_wake()                               # quiet check-in → re-sleep
    rig.t += 45                                          # woke again unseen; ticking means it's awake
    rig.wake.tick()
    rig.t += 30
    rig.wake.tick()
    assert not rig.wake.quiet() and not rig.wake.asleep() and rig.armed[-1] == rig.t + CHECKIN


class FiredRig(Rig):
    """A timer that, like Windows', stays signalled once it goes off until it's armed again."""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.fired = False
        self.wake._fired = lambda: self.fired
        self.wake._arm_fn = self._arm

    def _arm(self, at):
        self.armed.append(at)
        self.fired = False

    def timer_goes_off(self):
        self.t = self.armed[-1]
        self.fired = True


def test_a_late_will_sleep_after_the_timer_fired_doesnt_hide_it():
    # Live 2026-11-19 01:12 and 02:31: our timer woke it ("Wake Source: Timer - python") but it was taken for a real
    # wake — the app's will_sleep for the sleep that had just ended re-armed the timer and wiped its fired state.
    rig = FiredRig()
    rig.wake.on_will_sleep()
    rig.timer_goes_off()
    assert rig.wake.on_will_sleep() is False and rig.fired      # late: ignored, the signal survives
    assert rig.wake.on_did_wake() is False and rig.checkins == 1 and rig.suspends == 1


def test_every_classified_resume_consumes_the_fired_signal():
    # A wake he asked for must not leave the timer signalled (tick would never re-arm it again).
    rig = FiredRig(answer={"wake": True, "timer_on": True})
    rig.wake.on_will_sleep()
    rig.timer_goes_off()
    assert rig.wake.on_did_wake() is True and not rig.fired and rig.armed[-1] == rig.t + CHECKIN


def test_a_fired_timer_nobody_reported_is_checked_in_by_the_ticks():
    rig = FiredRig()
    rig.wake.on_will_sleep()
    rig.timer_goes_off()
    rig.t += 45
    rig.wake.tick()                                      # neither the app nor the clock check said "resumed"
    assert rig.checkins == 1 and rig.suspends == 1
