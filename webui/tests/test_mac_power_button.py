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

    def light(self, state, board=BOARD, wired=True):
        if wired and PC in self.store._devices:
            self.store.set_light_wired(PC, True)    # the light wires are connected (he says so; off by default)
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
    assert r["power_button"] == {"linked": False, "connected": False, "name": "", "light": "unknown", "light_wired": False}


# ── Task 4: wake / sleep fallback / clean restart + shutdown / force ───────────
WAKING = ["asleep", "off", "unknown"]


def asleep_pc(tmp_path, **kw):
    rig = Rig(tmp_path, **kw)
    rig.store.on_status(PC, PC_STATUS)
    rig.t += 300          # its last report is long gone: it's down
    return rig


def test_wake_presses_when_asleep(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("asleep")
    out = rig.store.wake(PC)
    assert out == {"ok": True, "sent": True, "via": "power button"}
    assert rig.presses()[0] == (BOARD, {"button": "power", "ms": 300, "expect": WAKING})


def test_wake_presses_when_off(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("off")
    assert rig.store.wake(PC)["via"] == "power button"
    assert rig.presses()[0][1]["button"] == "power"


def test_wake_when_light_on_does_not_press(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("on")                      # still booting from the first tap
    out = rig.store.wake(PC)
    assert out == {"ok": True, "already_on": True}
    assert rig.presses() == []
    assert rig.store.device(PC)["wake_requested_at"] == rig.t   # the PC's check-in mustn't sleep it again


def test_wake_when_pc_reporting_does_not_press(tmp_path):
    rig = Rig(tmp_path)                  # jc-client connected and fresh, light not wired (unknown)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.wake(PC)["already_on"] is True
    assert rig.presses() == []


def test_wake_falls_back_when_board_offline(tmp_path):
    rig = asleep_pc(tmp_path, connected=(MAC,))
    out = rig.store.wake(PC)
    assert out["via"] == "MacBook" and rig.presses() == []
    assert (MAC, "wol_send", {"mac": "aa:bb:cc:dd:ee:ff"}) in rig.invokes


def test_wake_falls_back_when_press_refused(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD, MAC),
                    press_result={"ok": False, "error": "the power light is on, so the press was refused"})
    rig.light("asleep")
    out = rig.store.wake(PC)
    assert out["via"] == "MacBook"
    assert any(s == "wol_send" for _, s, _ in rig.invokes)


def test_wake_fallback_after_15s_if_still_dark(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD, MAC))
    rig.light("asleep")
    rig.store.wake(PC)
    assert any(s == "wol_send" for _, s, _ in rig.invokes)   # 15 s later the light was still blinking


def test_wake_no_fallback_when_light_turns_on(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD, MAC))
    rig.light("asleep")
    rig.store._sleep = lambda s: (setattr(rig, "t", rig.t + s), rig.light("on"))
    rig.store.wake(PC)
    assert not any(s == "wol_send" for _, s, _ in rig.invokes)


def test_sleep_fallback_presses_when_still_on(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("on")
    rig.store.let_sleep(PC)
    assert any(f.get("let_sleep") for d, f in rig.frames if d == PC)
    assert rig.presses() == [(BOARD, {"button": "power", "ms": 300, "expect": ["on"]})]


def test_sleep_fallback_skips_when_it_slept(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("on")
    rig.store._sleep = lambda s: (setattr(rig, "t", rig.t + s), rig.light("asleep"))
    rig.store.let_sleep(PC)
    assert rig.presses() == []


def test_sleep_fallback_skips_when_action_not_sleep(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, dict(PC_STATUS, button_action="shutdown"))
    rig.light("on")
    rig.store.let_sleep(PC)
    assert rig.presses() == []


def test_sleep_fallback_skips_unknown_light(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)   # no light events: unknown
    rig.store.let_sleep(PC)
    assert rig.presses() == []


def test_sleep_fallback_skips_after_a_wake(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("on")
    rig.store._sleep = lambda s: (setattr(rig, "t", rig.t + s), rig.store.device(PC).update(wake_requested_at=rig.t))
    rig.store.let_sleep(PC)
    assert rig.presses() == []


def test_restart_and_shutdown_send_frames(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.restart(PC) == {"ok": True, "delivered": True}
    assert rig.store.shutdown(PC) == {"ok": True, "delivered": True}
    sent = [f for d, f in rig.frames if d == PC and f.get("type") == "mac_power_set"]
    assert sent[-2].get("restart") is True and sent[-1].get("shutdown") is True


def test_restart_when_pc_offline_errors(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    out = rig.store.restart(PC)
    assert out["ok"] is False and "isn't connected" in out["error"]


def test_force_off_holds_6000(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.force(PC, "force_off")["ok"] is True
    assert rig.presses() == [(BOARD, {"button": "power", "ms": 6000, "expect": ["any"]})]


def test_force_restart_presses_reset(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.force(PC, "force_restart")["ok"] is True
    assert rig.presses() == [(BOARD, {"button": "reset", "ms": 300, "expect": ["any"]})]


def test_force_without_board_errors(tmp_path):
    rig = Rig(tmp_path, connected=(PC,))
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.force(PC, "force_off")["ok"] is False


def test_restart_route(tmp_path, monkeypatch):
    from api import agents_routes
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)

    class C:
        mac_power = rig.store
    monkeypatch.setattr(agents_routes, "_core", lambda: C())
    status, body = agents_routes._v2("POST", "/agents/mac/restart", {}, {"device_id": PC})
    assert status == 200 and body["delivered"] is True
    status, body = agents_routes._v2("POST", "/agents/mac/shutdown", {}, {"device_id": PC})
    assert status == 200 and body["delivered"] is True



# ── Final review fixes ─────────────────────────────────────────────────────────
def test_wake_double_tap_presses_once(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("asleep")
    rig.store.wake(PC)
    rig.t += 1                      # a second tap while it's still resuming (light not steady yet)
    out = rig.store.wake(PC)
    assert len(rig.presses()) == 1 and out["via"] == "power button"


def test_sleep_fallback_skips_after_keyboard_wake(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("on")

    def later(s):
        rig.t += s                  # it slept, then he woke it with the keyboard: lit again 3 s ago
        rig.store.on_light(BOARD, {"light": "on", "since_s": 3, "plus_mv": 2400, "minus_mv": 0})
    rig.store._sleep = later
    rig.store.let_sleep(PC)
    assert rig.presses() == []


def test_sleep_fallback_skips_after_restart(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("on")
    rig.store._sleep = lambda s: (setattr(rig, "t", rig.t + s), rig.store.restart(PC))
    rig.store.let_sleep(PC)
    assert rig.presses() == []



# ── Live 2026-11-23: Force off left "Waking…"; an unwired power light read "off" ──
def test_force_clears_waking(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("asleep")
    rig.store.wake(PC)
    assert rig.store.device(PC)["wake_requested_at"] is not None
    rig.store.force(PC, "force_off")
    assert rig.store.device(PC)["wake_requested_at"] is None
    assert row(rig)["wake_requested_at"] is None


def test_light_untrusted_until_seen_lit(tmp_path):
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("off")                      # LED pins not wired: 0 V reads like a dark light
    assert rig.store.light(PC) == "unknown"
    assert row(rig)["state"] == "sleeping"
    rig.light("on")                       # wired: once it has been seen lit, dark means off
    rig.light("off")
    assert rig.store.light(PC) == "off"



def test_unwired_light_never_triggers_the_sleep_fallback(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.light("on", wired=False)
    rig.store.let_sleep(PC)
    assert rig.presses() == []


def test_light_wired_flag_round_trip(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.set_light_wired(PC, True)["ok"] is True
    assert row(rig)["power_button"]["light_wired"] is True
    rig.store.set_light_wired(PC, False)
    assert row(rig)["power_button"]["light_wired"] is False



def test_check_in_timer_stays_on_with_a_board(tmp_path):
    # His call 2026-11-23: the 15-minute check-in stays (the flow worked with it); a linked board doesn't touch it.
    rig = Rig(tmp_path)
    rig.store.on_status(PC, dict(PC_STATUS, timer_on=True))
    rig.store.on_set(PC, {"timer_on": True})
    assert rig.store.device(PC)["timer_on"] is True


def test_wake_skips_the_boards_light_check_while_the_light_is_unwired(tmp_path):
    # The board checks expect against its own reading of GPIO 34/35, which float until the LED wires
    # are connected: a stray "on" there would refuse the wake press.
    rig = asleep_pc(tmp_path, connected=(BOARD,))
    rig.light("on", wired=False)
    assert rig.store.wake(PC) == {"ok": True, "sent": True, "via": "power button"}
    assert rig.presses()[0] == (BOARD, {"button": "power", "ms": 300, "expect": ["any"]})


def test_wake_a_shut_down_pc_with_its_board_offline_says_why_at_once(tmp_path):
    # Live 2026-11-24: the board fell back to Bluetooth while the server was down, and "turn on my PC" waited
    # 2 minutes on a Wi-Fi wake that can't start a shut-down PC.
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.button_board(PC) == BOARD   # linked while both were online
    assert rig.store.shutdown(PC)["ok"] is True
    rig.connected = set()          # the PC is off and the board is offline
    rig.t += 300
    out = rig.store.wake(PC)
    assert out["ok"] is False and "Direct link" in out["error"]


def test_wake_a_sleeping_pc_with_its_board_offline_still_tries_wifi(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.store.on_sleeping(PC)
    rig.connected = {MAC}
    rig.t += 300
    assert "Direct link" not in str(rig.store.wake(PC))


def test_pc_reporting_again_clears_the_shutdown(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.store.shutdown(PC)
    rig.t += 300
    rig.store.on_status(PC, PC_STATUS)   # he turned it back on by hand
    rig.connected = set()
    rig.t += 300
    assert "Direct link" not in str(rig.store.wake(PC))
