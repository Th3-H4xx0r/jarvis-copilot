"""PC lighting setup steps (Jarvis does it: install OpenRGB, quit SignalRGB, check, measure the cost)."""
from types import SimpleNamespace

import pytest

from jc_client.pc_lighting import setup

USB = [{"index": 0, "name": "ASRock Polychrome USB", "location": "HID: \\\\?\\hid#vid_26ce", "zones": [{"index": 0}]}]
SMBUS = [{"index": 0, "name": "ASRock Polychrome V2", "location": "I2C: PIIX4 #0, address 0x6A", "zones": []}]


class Shell:
    def __init__(self, replies=None):
        self.calls = []
        self.replies = replies or {}

    def __call__(self, command, timeout_s=120):
        self.calls.append(command)
        for key, out in self.replies.items():
            if key in command:
                return {"ok": True, "exit_code": 0, "stdout": out, "stderr": ""}
        return {"ok": True, "exit_code": 0, "stdout": "", "stderr": ""}


class Admin:
    def __init__(self, result=None):
        self.calls = []
        self.result = result or {"ok": True, "status": "ran", "exit_code": 0, "output": "installed"}

    def __call__(self, command, why="", timeout_s=600, elevated=True):
        self.calls.append(command)
        return self.result


class Eng:
    def __init__(self, controllers=USB, cpu=0.4, reachable=True):
        self._c, self.cpu, self.reachable = controllers, cpu, reachable

    def status(self):
        return {"controllers": self._c if self.reachable else [], "engine": "running" if self.reachable else "error",
                "error": None if self.reachable else "Can't drive the lights through OpenRGB"}

    def reconnect(self):
        pass

    def measure(self, seconds=10.0):
        return self.cpu


def _run(step, *, shell=None, admin=None, eng=None, gaming=False, sensor_driver=True):
    return setup.run_step(step, sensor_driver=sensor_driver, admin_run=admin or Admin(), shell=shell or Shell(),
                          engine=eng or Eng(), game_state=lambda: SimpleNamespace(on=gaming, reason="", anticheat=False),
                          sleep=lambda s: None)


@pytest.mark.parametrize("step", ["openrgb", "signalrgb", "driver", "detect", "cost"])
def test_every_step_refuses_while_gaming(step):
    out = _run(step, gaming=True)
    assert out["state"] == "failed" and "game" in out["detail"].lower()


def test_openrgb_installs_once_through_face_id_and_starts_it():
    shell, admin = Shell({"Test-Path": "False"}), Admin()
    out = _run("openrgb", shell=shell, admin=admin)
    assert out["state"] == "done"
    assert len(admin.calls) == 1
    assert "winget install --id OpenRGB.OpenRGB" in admin.calls[0]
    assert "SignalRgbService" in admin.calls[0]               # same Face ID stops SignalRGB's service
    assert any("--server" in c and "--noautoconnect" in c for c in shell.calls)   # starts headless
    assert any("CurrentVersion\\Run" in c and "OpenRGB" in c for c in shell.calls)  # and at login


def test_openrgb_already_installed_needs_no_face_id():
    admin = Admin()
    out = _run("openrgb", shell=Shell({"Test-Path": "True"}), admin=admin)
    assert out["state"] == "done" and admin.calls == []


def test_openrgb_install_failure_reports_the_output():
    admin = Admin({"ok": True, "status": "ran", "exit_code": -1978335212, "output": "No package found"})
    out = _run("openrgb", shell=Shell({"Test-Path": "False"}), admin=admin)
    assert out["state"] == "failed" and "No package found" in out["detail"]


def test_openrgb_denied_face_id_fails_with_the_reason():
    admin = Admin({"ok": False, "status": "denied", "error": "denied"})
    out = _run("openrgb", shell=Shell({"Test-Path": "False"}), admin=admin)
    assert out["state"] == "failed" and "denied" in out["detail"].lower()


def test_openrgb_not_answering_after_start_fails():
    out = _run("openrgb", shell=Shell({"Test-Path": "True"}), eng=Eng(reachable=False))
    assert out["state"] == "failed" and "OpenRGB" in out["detail"]


def test_signalrgb_stops_it_and_removes_only_its_own_autostart():
    shell = Shell({"Get-Service": "Stopped"})
    admin = Admin()
    out = _run("signalrgb", shell=shell, admin=admin)
    assert out["state"] == "done"
    joined = "\n".join(shell.calls)
    assert "Stop-Process" in joined and "SignalRgb" in joined
    assert "Remove-ItemProperty" in joined and "-Name SignalRgb" in joined
    assert "Uninstall" not in joined and admin.calls == []


def test_signalrgb_service_still_running_is_stopped_through_face_id():
    admin = Admin()
    out = _run("signalrgb", shell=Shell({"Get-Service": "Running"}), admin=admin)
    assert out["state"] == "done" and len(admin.calls) == 1 and "SignalRgbService" in admin.calls[0]


def test_driver_is_skipped_for_usb_lights():
    out = _run("driver", eng=Eng(USB))
    assert out["state"] == "skipped"


def test_driver_needs_pc_stats_sensor_driver_for_smbus():
    out = _run("driver", eng=Eng(SMBUS), sensor_driver=False)
    assert out["state"] == "failed" and "sensor driver" in out["detail"]


def test_driver_updates_old_pawnio_through_face_id():
    admin = Admin()
    out = _run("driver", eng=Eng(SMBUS), shell=Shell({"PawnIO": "2.0.1"}), admin=admin)
    assert out["state"] == "done" and len(admin.calls) == 1 and "PawnIO" in admin.calls[0]


def test_detect_needs_at_least_one_controller():
    assert _run("detect", eng=Eng(USB))["state"] == "done"
    assert _run("detect", eng=Eng([]))["state"] == "failed"


def test_cost_freezes_in_games_for_smbus_lights():
    out = _run("cost", eng=Eng(SMBUS))
    assert out["state"] == "done" and out["still_in_games"] is True


def test_cost_keeps_effects_when_cheap_and_freezes_when_not():
    assert _run("cost", eng=Eng(USB, cpu=0.4))["still_in_games"] is False
    out = _run("cost", eng=Eng(USB, cpu=2.5))
    assert out["still_in_games"] is True and "2.5" in out["detail"]


def test_unknown_step_fails():
    assert _run("lava")["state"] == "failed"
