"""Restarts and outages mid-run. A restart only after his Face ID; then the run waits for him to sign in
(jc-client starts at sign-in; nothing signs in for him). A PC that went offline is woken once and waited for."""
from __future__ import annotations

from dataclasses import dataclass

from agent.it_agent.model import Deps, Limits, Run

RESTART_COMMAND = ('shutdown.exe /r /t 30 /c "Jarvis is restarting your PC to finish an IT task. '
                   'Sign in when it is back."')
_DOWN_WAIT_S = 300
APPROVAL_ASKS = 3     # a Face ID prompt he missed (2 minutes each) is asked again before the run stops
_REMIND_S = 900
_MAX_REMINDERS = 4


@dataclass
class WaitOutcome:
    status: str          # back · denied · approval_timeout · no_restart · timeout · stopped · error
    detail: str = ""


def with_face_id_retries(deps: Deps, call):
    """Run ``call`` (it asks his Face ID); when the prompt timed out, remind him and ask again, up to
    APPROVAL_ASKS in all. Denied, stopped and every other answer return at once."""
    res = call()
    for _ in range(APPROVAL_ASKS - 1):
        if getattr(res, "status", "") != "approval_timeout" or deps.should_stop():
            return res
        deps.notify("Still waiting for your Face ID", "Approve on your iPhone so I can keep going.")
        res = call()
    return res


def restart_and_wait(run: Run, deps: Deps, limits: Limits, phase_name: str) -> WaitOutcome:
    if deps.should_stop():
        return WaitOutcome("stopped")
    run.state = "restarting"
    deps.progress(run)
    res = with_face_id_retries(deps, lambda: deps.admin(RESTART_COMMAND, f"Restart to finish: {phase_name}"[:300], 60))
    if res.status == "stopped":
        return WaitOutcome("stopped")
    if res.status in ("denied", "approval_timeout"):
        return WaitOutcome(res.status, res.error)
    if res.status != "ran" or res.exit_code not in (0, None):
        return WaitOutcome("error", res.error or f"the restart command answered {res.status} {res.exit_code}")
    goal = run.goal[:80]
    deps.notify("Restarting your PC", f"Sign in when it's back so I can finish: {goal}")
    start = deps.clock()
    while deps.online():
        if deps.should_stop():
            return WaitOutcome("stopped")
        if deps.clock() - start >= _DOWN_WAIT_S:
            return WaitOutcome("no_restart", "the PC didn't go down within 5 minutes")
        deps.sleep(5)
    run.state = "signin"
    deps.progress(run)
    start = last = deps.clock()
    reminders = 0
    while True:
        if deps.should_stop():
            return WaitOutcome("stopped")
        online = deps.online()
        if online and deps.signed_in():
            return WaitOutcome("back")
        now = deps.clock()
        if now - start >= limits.reboot_wait_minutes * 60:
            return WaitOutcome("timeout", f"you didn't sign in within {limits.reboot_wait_minutes} minutes")
        if now - last >= _REMIND_S and reminders < _MAX_REMINDERS:
            reminders, last = reminders + 1, now
            if online:
                deps.notify("Waiting for you to sign in on your PC", f"Sign in so I can finish: {goal}")
            else:
                deps.notify("Waiting for your PC", f"Your PC hasn't come back yet: {goal}")
        deps.sleep(10)


def wait_for_pc(run: Run, deps: Deps, minutes: int) -> WaitOutcome:
    run.state = "offline"
    deps.progress(run)
    deps.wake()
    deps.notify("Your PC went offline", f"Wake it so I can finish: {run.goal[:80]}")
    start = deps.clock()
    while True:
        if deps.should_stop():
            return WaitOutcome("stopped")
        if deps.online():
            return WaitOutcome("back")
        if deps.clock() - start >= minutes * 60:
            return WaitOutcome("timeout", f"the PC didn't come back within {minutes} minutes")
        deps.sleep(10)
