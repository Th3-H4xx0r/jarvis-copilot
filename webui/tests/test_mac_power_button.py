"""The PC power button (spec 2026-11-23): an ESP32 on the PC's front-panel header presses its
power/reset buttons and reports the power light; the card's state comes from that light."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api.mac_power import MacPowerStore  # noqa: E402

PC, MAC, BOARD, BOARD2 = "dev-pc", "dev-mac", "dev-board", "dev-board2"
BUTTON_SKILLS = ["esp32_pc_press", "esp32_pc_power_state"]
PC_STATUS = {"os": "windows", "state": "awake", "held": False, "reason": "", "keep_awake": False,
             "battery": None, "on_ac": None, "lid": None, "wifi_mac": "aa:bb:cc:dd:ee:ff",
             "wake": {"capable": True, "adapter": "RZ616", "reason": ""}, "button_action": "sleep"}


class Rig:
    def __init__(self, tmp_path, connected=(PC, MAC, BOARD), press_result=None, extra_skills=None):
        self.t = 10_000.0
        self.frames, self.invokes = [], []
        self.connected = set(connected)
        self.press_result = press_result if press_result is not None else {"ok": True, "result": {"ok": True}}
        self.skills = {MAC: ["wol_send", "ui_look"], BOARD: list(BUTTON_SKILLS)}
        self.skills.update(extra_skills or {})
        os_map = {PC: "windows", MAC: "macos"}

        def invoke(d, skill, args):
            self.invokes.append((d, skill, args))
            if skill == "esp32_pc_press":
                return self.press_result
            return {"ok": True, "result": {"ok": True}}

        self.store = MacPowerStore(
            tmp_path / "mac_power.json",
            send_frame=lambda d, f: self.frames.append((d, f)) or d in self.connected,
            connected=lambda: self.connected, clock=lambda: self.t, invoke=invoke,
            os_of=lambda d: os_map.get(d, "macos"),
            skills_of=lambda d: self.skills.get(d, []),
            name_of=lambda d: {MAC: "MacBook", PC: "Pranav-Desktop", BOARD: "Jarvis-ESP32-A1B2"}.get(d, ""))
        self.store._spawn = lambda fn: fn()   # follow-up checks run inline in tests
        self.store._sleep = lambda s: setattr(self, "t", self.t + s)

    def light(self, state, board=BOARD):
        self.store.on_light(board, {"light": state, "since_s": 5, "plus_mv": 2400, "minus_mv": 0})

    def presses(self):
        return [(d, a) for d, s, a in self.invokes if s == "esp32_pc_press"]


def row(rig, did=PC):
    return next(m for m in rig.store.list_payload(lambda d: "")["mac"] if m["device_id"] == did)


def test_board_skills_are_server_only():
    from api import device_bridge
    assert {"esp32_pc_press", "esp32_pc_power_state"} <= set(device_bridge.SERVER_ONLY_SKILLS)


def test_autolink_single_board(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.button_board(PC) == BOARD
    assert rig.store.device(PC)["button_board"] == BOARD
    pb = row(rig)["power_button"]
    assert pb["linked"] is True and pb["connected"] is True and pb["name"] == "Jarvis-ESP32-A1B2"


def test_two_boards_no_autolink(tmp_path):
    rig = Rig(tmp_path, connected=(PC, BOARD, BOARD2), extra_skills={BOARD2: list(BUTTON_SKILLS)})
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.button_board(PC) == ""
    assert row(rig)["power_button"]["linked"] is False


def test_light_event_drives_state(tmp_path):
    rig = Rig(tmp_path, connected=(BOARD,))   # jc-client asleep / off: only the board is online
    rig.store.on_status(PC, PC_STATUS)
    rig.t += 300   # the PC's last report is long gone
    rig.light("asleep")
    assert row(rig)["state"] == "sleeping" and row(rig)["power_button"]["light"] == "asleep"
    rig.light("off")
    assert row(rig)["state"] == "off"
    rig.light("on")
    r = row(rig)
    assert r["state"] == "awake" and r["reason"] == "starting"   # lit, but Jarvis isn't connected yet


def test_light_stale_is_unknown(tmp_path):
    rig = Rig(tmp_path, connected=(BOARD,))
    rig.store.on_status(PC, PC_STATUS)
    rig.light("off")
    rig.t += 151
    assert rig.store.light(PC) == "unknown"
    assert row(rig)["state"] == "sleeping"   # back to today's rule: not reporting = asleep


def test_board_offline_light_unknown(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("off")
    rig.connected.discard(BOARD)
    assert rig.store.light(PC) == "unknown"
    pb = row(rig)["power_button"]
    assert pb["linked"] is True and pb["connected"] is False


def test_no_board_payload_unchanged(tmp_path):
    rig = Rig(tmp_path, connected=(PC, MAC))
    rig.skills.pop(BOARD)
    rig.store.on_status(PC, PC_STATUS)
    r = row(rig)
    assert r["state"] == "awake" and r["reason"] == ""
    assert r["power_button"] == {"linked": False, "connected": False, "name": "", "light": "unknown"}
