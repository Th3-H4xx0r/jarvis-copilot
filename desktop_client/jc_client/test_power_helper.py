"""The root power helper's state machine and the one-time installer's sudo.conf edit."""
from __future__ import annotations

import time

from jc_client.power_helper.jarvis_power import WATCHDOG, HelperState, wake_stamp
from jc_client.power_install import ASKPASS_PATH, sudo_conf_with_askpass


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def make():
    calls = []
    clock = Clock()
    return HelperState(lambda argv: calls.append(list(argv)) or 0, clock=clock), calls, clock


def test_start_resets_disablesleep():
    _state, calls, _ = make()
    assert calls == [["pmset", "-a", "disablesleep", "0"]]


def test_hold_on_off_runs_pmset():
    state, calls, _ = make()
    calls.clear()
    assert state.handle({"op": "hold", "on": True}) == {"ok": True, "held": True, "wake_at": None}
    state.handle({"op": "hold", "on": True})          # no change, no second call
    assert state.handle({"op": "hold", "on": False})["held"] is False
    assert calls == [["pmset", "-a", "disablesleep", "1"], ["pmset", "-a", "disablesleep", "0"]]


def test_watchdog_releases_without_heartbeat():
    state, calls, clock = make()
    state.handle({"op": "hold", "on": True})
    clock.t += WATCHDOG - 1
    state.handle({"op": "heartbeat"})
    clock.t += WATCHDOG - 1
    state.tick()
    assert state.held is True
    clock.t += 2
    calls.clear()
    state.tick()
    assert state.held is False
    assert calls == [["pmset", "-a", "disablesleep", "0"]]
    assert WATCHDOG == 35.0


def test_wake_at_replaces_previous_schedule():
    state, calls, clock = make()
    calls.clear()
    first, second = clock.t + 900, clock.t + 1800
    assert state.handle({"op": "wake_at", "ts": first})["wake_at"] == first
    state.handle({"op": "wake_at", "ts": second})
    assert calls == [["pmset", "schedule", "wake", wake_stamp(first)],
                     ["pmset", "schedule", "cancel", "wake", wake_stamp(first)],
                     ["pmset", "schedule", "wake", wake_stamp(second)]]
    calls.clear()
    assert state.handle({"op": "cancel_wake"})["wake_at"] is None
    assert calls == [["pmset", "schedule", "cancel", "wake", wake_stamp(second)]]


def test_wake_in_the_past_is_refused():
    state, calls, clock = make()
    calls.clear()
    assert state.handle({"op": "wake_at", "ts": clock.t - 5})["ok"] is False
    assert calls == []


def test_passed_wake_is_forgotten():
    state, calls, clock = make()
    state.handle({"op": "wake_at", "ts": clock.t + 60})
    clock.t += 61
    state.tick()
    calls.clear()
    assert state.handle({"op": "cancel_wake"})["wake_at"] is None
    assert calls == []                               # nothing left to cancel


def test_sleepnow():
    state, calls, _ = make()
    calls.clear()
    assert state.handle({"op": "sleepnow"})["ok"] is True
    assert calls == [["pmset", "sleepnow"]]


def test_rejects_unknown_op():
    state, calls, _ = make()
    calls.clear()
    assert state.handle({"op": "rm -rf"}) == {"ok": False, "error": "unknown op"}
    assert calls == []


def test_wake_stamp_is_pmset_local_format():
    ts = time.mktime((2026, 11, 3, 9, 5, 7, 0, 0, -1))
    assert wake_stamp(ts) == "11/03/26 09:05:07"


def test_install_script_keeps_existing_sudo_conf_lines():
    text = "# sudo.conf\nPlugin sudoers_policy sudoers.so\nSet disable_coredump false\n"
    out = sudo_conf_with_askpass(text)
    assert out.startswith(text)
    assert out.endswith(f"Path askpass {ASKPASS_PATH}\n")
    assert sudo_conf_with_askpass(out) == out                      # idempotent
    other = "Path askpass /usr/local/bin/other\nSet x y\n"
    assert sudo_conf_with_askpass(other) == f"Path askpass {ASKPASS_PATH}\nSet x y\n"
    assert sudo_conf_with_askpass("") == f"Path askpass {ASKPASS_PATH}\n"


def test_install_script_writes_files_from_itself_not_a_user_folder():
    from jc_client.power_install import HELPER_PATH, PLIST_PATH, _script
    script = _script([(HELPER_PATH, "644", b"print('hi')\n"), (PLIST_PATH, "644", b"<plist/>")])
    assert "/tmp" not in script and "TMPDIR" not in script and "/var/folders" not in script
    assert "base64 -D" in script and f"mv -f {HELPER_PATH}.jc-new {HELPER_PATH}" in script
    assert script.rstrip().endswith(f"launchctl bootstrap system {PLIST_PATH}")
    import subprocess, os, tempfile
    with tempfile.TemporaryDirectory() as d:   # the decode really reproduces the bytes
        target = os.path.join(d, "f")
        body = _script([(target, "644", b"\x00bytes\n")]).split("\n")
        line = [ln for ln in body if "base64 -D" in ln][0].replace(f"{target}.jc-new", target)
        subprocess.run(["/bin/sh", "-c", "rm -f " + target + "; " + line], check=True)
        assert open(target, "rb").read() == b"\x00bytes\n"


def test_wake_at_rejects_nan_inf_and_far_future():
    state, calls, clock = make()
    calls.clear()
    for bad in ("nan", "inf", clock.t + 8 * 86400):
        assert state.handle({"op": "wake_at", "ts": bad})["ok"] is False
    assert calls == []
