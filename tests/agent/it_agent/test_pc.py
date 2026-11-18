"""Server side of the PC tools: pc_shell / admin_run over the device bridge, watched for the PC dropping
off or the card's Stop; the tools never become model tools."""
import sys
import threading
import time
from pathlib import Path

import pytest

from agent.it_agent import pc
from agent.it_agent.model import SIGNED_IN_SCRIPT

OK_RUN = {"ok": True, "result": {"ok": True, "exit_code": 0, "stdout": "hi", "stderr": "", "truncated": False,
                                 "timed_out": False, "duration_ms": 5}}


class FakeBridge:
    def __init__(self, result=None, connected=("pc",), block=False, rows=None, skills=None):
        self.calls = []
        self.result = result if result is not None else OK_RUN
        self.connected = list(connected)
        self.block = block
        self.release = threading.Event()
        self.rows = rows if rows is not None else [{"device_id": "pc", "device_name": "Pranav-Desktop",
                                                    "name": "pc_shell"}]
        self.skills = skills if skills is not None else {"pc": [{"name": "pc_shell"}, {"name": "admin_run"}]}

    def invoke_skill(self, did, skill, args, timeout=30.0):
        self.calls.append((did, skill, args, timeout))
        if self.block:
            self.release.wait(5)
        return self.result

    def connected_device_ids(self):
        return list(self.connected)

    def catalog_device_skills(self):
        return list(self.rows)

    def skills_for_device(self, did):
        return self.skills.get(did, [])


@pytest.fixture
def bridge(monkeypatch):
    def use(**kw):
        fake = FakeBridge(**kw)
        monkeypatch.setattr(pc, "_bridge", lambda: fake)
        monkeypatch.setattr(pc, "POLL_S", 0.01)
        return fake
    return use


def never():
    return False


def test_shell_invokes_pc_shell_and_waits_long_enough(bridge):
    fake = bridge()
    r = pc.shell("pc", "docker --version", 120, never)
    assert fake.calls[0] == ("pc", "pc_shell", {"command": "docker --version", "timeout_s": 120}, 140)
    assert (r.status, r.exit_code, r.output, r.routed) == ("ran", 0, "hi", "shell")


def test_shell_maps_timeout_and_stderr(bridge):
    bridge(result={"ok": True, "result": {"ok": True, "exit_code": None, "stdout": "pulling", "stderr": "hung",
                                          "truncated": True, "timed_out": True, "duration_ms": 120000}})
    r = pc.shell("pc", "docker run hello-world", 120, never)
    assert r.status == "timeout" and r.output == "pulling\nhung" and r.truncated and r.exit_code is None


def test_admin_waits_for_approval_plus_run(bridge):
    fake = bridge(result={"ok": True, "result": {"ok": False, "status": "approval_timeout", "exit_code": None,
                                                 "output": "", "error": "No answer in 2 minutes"}})
    r = pc.admin("pc", "wsl --install --no-distribution", "Enable WSL2", 600, never)
    did, skill, args, timeout = fake.calls[0]
    assert skill == "admin_run" and timeout == 120 + 600 + 45
    assert args == {"command": "wsl --install --no-distribution", "why": "Enable WSL2", "timeout_s": 600}
    assert r.status == "approval_timeout" and r.routed == "admin"


def test_admin_maps_failed_to_error_and_ran_to_ran(bridge):
    bridge(result={"ok": True, "result": {"ok": False, "status": "failed", "error": "helper not running"}})
    assert pc.admin("pc", "dism /online", "x", 600, never).status == "error"
    bridge(result={"ok": True, "result": {"ok": True, "status": "ran", "exit_code": 3010, "output": "done"}})
    r = pc.admin("pc", "dism /online", "x", 600, never)
    assert (r.status, r.exit_code, r.output) == ("ran", 3010, "done")


def test_approved_command_asks_face_id_then_runs_unelevated(bridge):
    fake = bridge(result={"ok": True, "result": {"ok": True, "status": "ran", "exit_code": 0, "output": "removed"}})
    r = pc.approved("pc", "winget remove x", "clean up (uninstalls software)", 300, never)
    _, skill, args, timeout = fake.calls[0]
    assert skill == "admin_run" and args["elevated"] is False and args["command"] == "winget remove x"
    assert timeout == 120 + 300 + 45 and r.routed == "approved" and r.status == "ran"


def test_invoke_watched_reports_offline_when_pc_drops(bridge):
    fake = bridge(block=True, connected=())
    start = time.monotonic()
    out = pc._invoke_watched("pc", "pc_shell", {"command": "x", "timeout_s": 600}, 620, never)
    fake.release.set()
    assert out == {"ok": False, "error": "offline"} and time.monotonic() - start < 2
    fake2 = bridge(block=True, connected=())
    r = pc.shell("pc", "winget install x", 600, never)
    fake2.release.set()
    assert r.status == "offline"


def test_invoke_watched_stops_on_card_stop(bridge):
    fake = bridge(block=True)
    out = pc._invoke_watched("pc", "pc_shell", {"command": "x", "timeout_s": 600}, 620, lambda: True)
    fake.release.set()
    assert out == {"ok": False, "error": "stopped"}


def test_device_error_while_offline_is_offline(bridge):
    bridge(result={"ok": False, "error": "send failed: broken pipe"}, connected=())
    assert pc.shell("pc", "x", 60, never).status == "offline"
    bridge(result={"ok": False, "error": "device has no skill named 'pc_shell'"})
    r = pc.shell("pc", "x", 60, never)
    assert r.status == "error" and "pc_shell" in r.error


def test_find_pc_prefers_the_named_pc(bridge):
    rows = [{"device_id": "pc1", "device_name": "Office-PC", "name": "pc_shell"},
            {"device_id": "pc1", "device_name": "Office-PC", "name": "admin_run"},
            {"device_id": "pc2", "device_name": "Gaming-Rig", "name": "pc_shell"},
            {"device_id": "mac", "device_name": "MacBook", "name": "ui_look"}]
    bridge(rows=rows)
    assert pc.find_pc("install docker on my gaming-rig") == ("pc2", "Gaming-Rig", "")
    assert pc.find_pc("") == ("pc1", "Office-PC", "")
    bridge(rows=[{"device_id": "mac", "device_name": "MacBook", "name": "ui_look"}])
    assert pc.find_pc("x") == (None, "", "No PC with Jarvis (jc-client) is paired for IT tasks. Update jc-client "
                                         "on the PC (`jc-client update`).")


def test_online_needs_a_live_pc_shell(bridge):
    bridge()
    assert pc.online("pc") is True
    bridge(skills={"pc": [{"name": "ui_look"}]})
    assert pc.online("pc") is False
    bridge(connected=())
    assert pc.online("pc") is False


def test_signed_in_probe(bridge):
    fake = bridge(result={"ok": True, "result": {**OK_RUN["result"], "stdout": "yes\r\n"}})
    assert pc.signed_in("pc") is True
    assert fake.calls[0][2] == {"command": SIGNED_IN_SCRIPT, "timeout_s": 15}
    bridge(result={"ok": True, "result": {**OK_RUN["result"], "stdout": "no"}})
    assert pc.signed_in("pc") is False


def test_pc_tools_are_never_model_tools():
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))
    from api import device_bridge
    assert {"pc_shell", "admin_run"} <= device_bridge.SERVER_ONLY_SKILLS


def test_refused_and_watchdog_results_are_labelled(bridge):
    bridge(result={"ok": True, "result": {"ok": False, "error": "command too long (max 8000 characters)"}})
    r = pc.shell("pc", "x", 60, never)
    assert r.status == "error" and "too long" in r.error
    bridge(result={"ok": False, "error": "skill 'pc_shell' timed out after 135s"})
    assert pc.shell("pc", "x", 120, never).status == "timeout"
