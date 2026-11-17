"""A Windows PC is called a PC (or its own name), never "Mac", in the Agents card, its errors and pushes."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from agent.coding_session_db import CodingSessionStore  # noqa: E402
from api import agents_core, device_bridge  # noqa: E402
from api.mac_power import MacPowerStore  # noqa: E402

PC, MAC = "dev-pc", "dev-mac"
OS = {PC: "windows", MAC: "macos"}


def _power(tmp_path, connected=(), alerts=None):
    store = MacPowerStore(
        tmp_path / "mac_power.json", send_frame=lambda d, f: d in connected, connected=lambda: set(connected),
        clock=lambda: 10_000.0, invoke=lambda d, s, a: {"ok": True}, os_of=lambda d: OS.get(d, "macos"),
        skills_of=lambda d: [], name_of=lambda d: "",
        alert=lambda title, body, data: alerts.append(title) if alerts is not None else None)
    store.on_status(PC, {"os": "windows", "state": "awake"})
    store.on_status(MAC, {"os": "macos", "state": "awake"})
    return store


def _row(store, did, name_of=lambda d: ""):
    return next(m for m in store.list_payload(name_of)["mac"] if m["device_id"] == did)


def test_offline_pc_without_a_name_is_called_pc(tmp_path):
    store = _power(tmp_path)
    assert _row(store, PC)["name"] == "PC"
    assert _row(store, MAC)["name"] == "Mac"


def test_answer_to_an_offline_pc_says_pc(tmp_path):
    store = _power(tmp_path)
    store.on_password_request(PC, {"id": "r1", "kind": "rdp", "context": "{}"})
    assert store.answer("r1", "allow", 1, "sig")["error"] == "The PC isn't connected."


def test_pc_password_alerts_say_pc(tmp_path):
    alerts = []
    store = _power(tmp_path, connected=(PC,), alerts=alerts)
    store.on_password_request(PC, {"id": "r2", "kind": "other", "context": "x"})
    store.on_password_done(PC, {"id": "r2", "ok": False, "error": "Wrong password"})
    assert alerts == ["PC password requested", "PC password not filled"]


def test_mac_password_alerts_still_say_mac(tmp_path):
    alerts = []
    store = _power(tmp_path, connected=(MAC,), alerts=alerts)
    store.on_password_request(MAC, {"id": "r3", "kind": "other", "context": "x"})
    store.on_password_done(MAC, {"id": "r3", "ok": False, "error": "Wrong password"})
    assert alerts == ["Mac password requested", "Mac password not filled"]


def test_device_name_falls_back_to_the_paired_name_when_offline(monkeypatch):
    import api.pairing as pairing
    monkeypatch.setattr(pairing, "list_devices",
                        lambda: [{"id": PC, "name": "Pranav-Desktop"}, {"id": "dev-x", "name": "device"}])
    assert device_bridge.device_name(PC) == "Pranav-Desktop"
    assert device_bridge.device_name("dev-x") == ""
    assert device_bridge.device_name("dev-unknown") == ""


def _core(tmp_path, power, pushes):
    store = CodingSessionStore(str(tmp_path / "c.db"))
    return agents_core.AgentsCore(store, send_frame=lambda d, f: False, device_name=lambda d: "",
                                  alert_phones=lambda title, body, **kw: pushes.append(title) or 1,
                                  mac_power=power)


def test_agents_core_calls_an_unnamed_pc_pc(tmp_path):
    pushes = []
    core = _core(tmp_path, _power(tmp_path), pushes)
    assert core._name(PC) == "PC" and core._name(MAC) == "Mac"
    assert core.launch({"where": PC, "cwd": "C:\\code"})["error"] == "The PC is asleep or offline."
    assert core.launch({"where": MAC, "cwd": "/Users/x"})["error"] == "The Mac is asleep or offline."
    core._push_paused({"count": 1, "kind": "offline", "device_id": PC})
    assert pushes == ["Your PC went offline"]


def test_session_rows_say_which_computer_they_run_on(tmp_path):
    core = _core(tmp_path, _power(tmp_path), [])
    base = {"ckey": "k", "agent": "claude", "status": "live", "cwd": "/x", "session_id": "s"}
    assert core._present({**base, "owner": PC}, None, {})["owner_os"] == "windows"
    assert core._present({**base, "owner": MAC}, None, {})["owner_os"] == "macos"
    assert core._present({**base, "owner": "server", "moved_from": PC}, None, {})["owner_os"] == "windows"
