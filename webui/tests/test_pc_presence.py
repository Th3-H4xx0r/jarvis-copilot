"""The PC's on/off state is right on the Agents card (live 2026-11-17: a sleeping PC showed Awake for
20+ minutes through Cloudflare, Sleep flipped back to Awake, a failed wake stuck on "Waking…")."""
from __future__ import annotations

import os
import sys
import time

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from agent.coding_session_db import CodingSessionStore  # noqa: E402
from api import agents_core, device_bridge, screen_share  # noqa: E402
from api.mac_power import MacPowerStore  # noqa: E402

PC = "dev-pc"
PC_STATUS = {"os": "windows", "state": "awake", "wifi_mac": "aa:bb:cc:dd:ee:ff",
             "wake": {"capable": True, "reason": ""}}


class Conn:
    def __init__(self, os_name="windows", pings=True, last_seen=0.0):
        self.os, self.pings, self.last_seen, self.closed = os_name, pings, last_seen, False


# ── 1A: a half-open connection through the tunnel is noticed ─────────────────

def test_a_silent_computer_connection_is_stale():
    now = 1000.0
    assert device_bridge._stale(Conn(last_seen=now - 80), now) is True
    assert device_bridge._stale(Conn(last_seen=now - 30), now) is False
    assert device_bridge._stale(Conn(os_name="macos", last_seen=now - 80), now) is True
    assert device_bridge._stale(Conn(os_name="", last_seen=now - 80), now) is False      # the phone: push wakes it
    assert device_bridge._stale(Conn(pings=False, last_seen=now - 80), now) is False     # an old client


def test_a_stale_computer_isnt_listed_as_connected(monkeypatch):
    monkeypatch.setattr(device_bridge, "_REG", {"pc": Conn(last_seen=time.time() - 300),
                                                "mac": Conn(os_name="macos", last_seen=time.time())})
    assert device_bridge.connected_device_ids() == ["mac"]


# ── the power store ──────────────────────────────────────────────────────────

class Rig:
    def __init__(self, tmp_path, connected=(PC,)):
        self.t = 10_000.0
        self.connected = set(connected)
        self.frames = []
        self.wol = {"ok": True, "result": {"ok": True}}
        self.store = MacPowerStore(
            tmp_path / "mac_power.json", clock=lambda: self.t, connected=lambda: self.connected,
            send_frame=lambda d, f: self.frames.append(f) or d in self.connected,
            invoke=lambda d, s, a: self.wol, os_of=lambda d: "windows" if d == PC else "macos",
            skills_of=lambda d: ["wol_send"] if d == "mac" else [], name_of=lambda d: "")

    def state(self):
        return next(m for m in self.store.list_payload(lambda d: "")["mac"] if m["device_id"] == PC)["state"]


def test_a_pc_that_stopped_reporting_isnt_awake(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.state() == "awake"
    rig.t += 200          # it reports every 60 s: three missed reports
    assert rig.state() == "sleeping"


def test_sleep_isnt_undone_by_the_report_it_sends_while_suspending(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.store.let_sleep(PC)
    rig.t += 2
    rig.store.on_status(PC, PC_STATUS)   # the last report on its way down
    assert rig.state() == "sleeping"
    rig.t += 60
    rig.store.on_status(PC, PC_STATUS)   # really back
    assert rig.state() == "awake"


def test_a_failed_wake_leaves_no_waking(tmp_path):
    rig = Rig(tmp_path, connected=("mac",))
    rig.store.on_status(PC, PC_STATUS)
    rig.wol = {"ok": True, "result": {"ok": False, "error": "no route"}}
    out = rig.store.wake(PC)
    row = next(m for m in rig.store.list_payload(lambda d: "")["mac"] if m["device_id"] == PC)
    assert out["ok"] is False and row["wake_requested_at"] is None


def test_power_commands_carry_when_they_were_sent(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.store.lock(PC)
    rig.store.let_sleep(PC)
    assert all(f.get("ts") == rig.t for f in rig.frames if f.get("type") == "mac_power_set")


# ── 1E: a disconnect reaches the phone at once ───────────────────────────────

def test_a_disconnect_pushes_the_list(tmp_path):
    pushed = []
    core = agents_core.AgentsCore(CodingSessionStore(str(tmp_path / "c.db")), send_frame=lambda d, f: False,
                                  publish=lambda topic, data: pushed.append(topic))
    core.on_disconnect(PC)
    assert "agents_list" in pushed


# ── 2B: Screen knows the PC is online from its connection ─────────────────────

def test_a_pc_share_is_online_while_the_pc_is_connected(tmp_path, monkeypatch):
    reg = screen_share.Registry(tmp_path)
    monkeypatch.setattr(screen_share, "_os_of", lambda d: "windows")
    monkeypatch.setattr(device_bridge, "connected_device_ids", lambda: [PC])
    share = reg.create("anytime", device_id=PC)
    assert reg.view(reg._shares[share["id"]], now=time.time() + 60)["mac_online"] is True   # no poll for a minute
    monkeypatch.setattr(device_bridge, "connected_device_ids", lambda: [])
    assert reg.view(reg._shares[share["id"]], now=time.time() + 60)["mac_online"] is False
