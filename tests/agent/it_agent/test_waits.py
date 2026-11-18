"""Restart only after his Face ID, then wait for him to sign in; wait for a PC that went offline."""
from agent.it_agent.model import Deps, Limits, Run, ScreenResult, ShellResult
from agent.it_agent.waits import RESTART_COMMAND, restart_and_wait, wait_for_pc


class Clock:
    def __init__(self):
        self.t = 0.0

    def sleep(self, s):
        self.t += s

    def now(self):
        return self.t


def _deps(clock, online, signed_in=lambda: True, admin_status="ran", stop=lambda: False):
    rec = {"admin": [], "notify": [], "wake": 0, "progress": []}
    nothing = lambda *a, **k: None  # noqa: E731

    def wake():
        rec["wake"] += 1

    deps = Deps(ask=nothing, search=lambda q: [], extract=lambda u: [], shell=lambda c, t: ShellResult("ran"),
                admin=lambda c, w, t: rec["admin"].append((c, w, t)) or ShellResult(admin_status, 0 if admin_status == "ran" else None),
                screen=lambda g: ScreenResult(True), read_screen=lambda a: "", online=online, signed_in=signed_in,
                wake=wake, notify=lambda title, body: rec["notify"].append(title),
                progress=lambda run: rec["progress"].append(run.state), should_stop=stop,
                sleep=clock.sleep, clock=clock.now)
    return deps, rec


def _run():
    return Run(goal="install Docker Desktop", request_text="install docker", device_id="d", device_name="PC")


def _seq(*values):
    vals = list(values)
    return lambda: vals.pop(0) if len(vals) > 1 else vals[0]


def test_restart_asks_face_id_with_fixed_command():
    clock = Clock()
    deps, rec = _deps(clock, online=_seq(True, False, True))
    restart_and_wait(_run(), deps, Limits(), "Enable WSL2")
    assert rec["admin"][0][0] == RESTART_COMMAND and "Enable WSL2" in rec["admin"][0][1]


def test_restart_declined():
    for status in ("denied", "approval_timeout"):
        clock = Clock()
        deps, _ = _deps(clock, online=lambda: True, admin_status=status)
        assert restart_and_wait(_run(), deps, Limits(), "x").status == status


def test_restart_waits_for_offline_then_signed_in():
    clock = Clock()
    signed = _seq(False, True)
    deps, rec = _deps(clock, online=_seq(True, True, False, False, True, True), signed_in=signed)
    out = restart_and_wait(_run(), deps, Limits(), "Enable WSL2")
    assert out.status == "back"
    assert "Restarting your PC" in rec["notify"] and "signin" in rec["progress"]


def test_restart_never_went_down():
    clock = Clock()
    deps, _ = _deps(clock, online=lambda: True)
    assert restart_and_wait(_run(), deps, Limits(), "x").status == "no_restart"


def test_signin_wait_times_out():
    clock = Clock()
    deps, rec = _deps(clock, online=_seq(True, False), signed_in=lambda: False)
    out = restart_and_wait(_run(), deps, Limits(reboot_wait_minutes=60), "x")
    reminders = [t for t in rec["notify"] if t.startswith("Waiting for")]
    assert out.status == "timeout" and 1 <= len(reminders) <= 4


def test_wait_for_pc_wakes_once_and_pings_once():
    clock = Clock()
    deps, rec = _deps(clock, online=_seq(False, False, True))
    out = wait_for_pc(_run(), deps, 30)
    assert out.status == "back" and rec["wake"] == 1 and rec["notify"] == ["Your PC went offline"]


def test_waits_stop_on_card_stop():
    clock = Clock()
    deps, _ = _deps(clock, online=lambda: False, stop=lambda: True)
    assert wait_for_pc(_run(), deps, 30).status == "stopped"
    deps2, _ = _deps(Clock(), online=lambda: True, stop=lambda: True)
    assert restart_and_wait(_run(), deps2, Limits(), "x").status == "stopped"


def test_stop_while_the_restart_waits_for_face_id():
    clock = Clock()
    deps, _ = _deps(clock, online=lambda: True, admin_status="stopped")
    assert restart_and_wait(_run(), deps, Limits(), "x").status == "stopped"
