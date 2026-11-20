"""The PC in the Agents power card (spec §6b): it reports like the Mac, wakes over Wi-Fi through
another computer's wol_send, locks and sleeps, and unlocks through the Face ID password flow."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api.mac_power import MacPowerStore  # noqa: E402

PC, MAC, PHONE = "dev-pc", "dev-mac", "dev-phone"
PC_STATUS = {"os": "windows", "state": "awake", "held": False, "reason": "", "keep_awake": False,
             "battery": None, "on_ac": None, "lid": None, "wifi_mac": "aa:bb:cc:dd:ee:ff",
             "wake": {"capable": True, "adapter": "Intel(R) Wi-Fi 6E AX211", "reason": ""}}


class Rig:
    def __init__(self, tmp_path, connected=(PC, MAC), skills=None):
        self.t = 10_000.0
        self.frames, self.invokes = [], []
        self.connected = set(connected)
        self.skills = skills if skills is not None else {MAC: ["wol_send", "ui_look"], PHONE: ["vibrate"]}
        os_map = {PC: "windows", MAC: "macos", PHONE: "macos"}
        self.store = MacPowerStore(
            tmp_path / "mac_power.json",
            send_frame=lambda d, f: self.frames.append((d, f)) or d in self.connected,
            connected=lambda: self.connected, clock=lambda: self.t,
            invoke=lambda d, skill, args: self.invokes.append((d, skill, args)) or {"ok": True, "result": {"ok": True}},
            os_of=lambda d: os_map.get(d, "macos"),
            skills_of=lambda d: self.skills.get(d, []),
            name_of=lambda d: {MAC: "MacBook", PC: "Pranav-Desktop"}.get(d, ""))


def _row(rig, did):
    return next(m for m in rig.store.list_payload(lambda d: "")["mac"] if m["device_id"] == did)


def test_pc_status_row_has_os_and_wake(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    row = _row(rig, PC)
    assert row["os"] == "windows" and row["wake_capable"] is True and row["wake_reason"] == ""


def test_old_mac_row_defaults_to_macos(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(MAC, {"state": "awake", "held": False})
    row = _row(rig, MAC)
    assert row["os"] == "macos" and row["wake_capable"] is None


def test_wake_pc_sends_wol_via_mac(tmp_path):
    rig = Rig(tmp_path, connected={MAC, PHONE})
    rig.store.on_status(PC, PC_STATUS)
    out = rig.store.wake(PC)
    assert out == {"ok": True, "sent": True, "via": "MacBook"}
    assert rig.invokes == [(MAC, "wol_send", {"mac": "aa:bb:cc:dd:ee:ff"})]
    assert rig.store.device(PC)["wake_requested_at"] == rig.t


def test_wake_pc_aims_at_its_last_address(tmp_path):
    rig = Rig(tmp_path, connected={MAC, PHONE})
    rig.store.on_status(PC, dict(PC_STATUS, wifi_ip="192.168.1.80"))
    assert rig.store.wake(PC)["ok"] is True
    assert rig.invokes == [(MAC, "wol_send", {"mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.1.80"})]


def test_wake_pc_without_sender_errors(tmp_path):
    rig = Rig(tmp_path, connected={PHONE})
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.wake(PC) == {"ok": False, "error": "No other computer is online to wake the PC."}
    assert rig.invokes == []


def test_wake_pc_incapable_adapter_errors(tmp_path):
    rig = Rig(tmp_path, connected={MAC})
    rig.store.on_status(PC, dict(PC_STATUS, wake={"capable": False, "adapter": "x", "reason": "no"}))
    assert rig.store.wake(PC) == {"ok": False, "error": "This PC's Wi-Fi adapter can't be woken remotely."}
    assert rig.invokes == []


def test_wake_pc_failed_send_reports(tmp_path):
    rig = Rig(tmp_path, connected={MAC})
    rig.store._invoke = lambda d, s, a: {"ok": False, "error": "boom"}
    rig.store.on_status(PC, PC_STATUS)
    out = rig.store.wake(PC)
    assert out["ok"] is False and "MacBook" in out["error"]


def test_lock_sends_set_frame(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.lock(PC) == {"ok": True, "delivered": True}
    assert rig.frames[-1] == (PC, {"type": "mac_power_set", "ts": rig.t, "lock": True})


def test_unlock_pc_asks_the_pc(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.unlock(PC) == {"ok": True}
    assert rig.frames[-1] == (PC, {"type": "mac_password_unlock"})


def test_unlock_pc_offline_says_wake_it(tmp_path):
    rig = Rig(tmp_path, connected=(MAC,))
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.unlock(PC) == {"ok": False, "error": "The PC isn't awake. Wake it first."}
    assert rig.frames == []


def test_pc_unlock_request_alert_says_pc(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    alerts = []
    rig.store._alert = lambda title, body, data: alerts.append((title, body, data["kind"]))
    rig.store.on_password_request(PC, {"id": "r1", "kind": "unlock", "context": "Unlock PC", "nonce": "n"})
    assert alerts == [("Unlock your PC", "Unlock PC", "mac_password")]


def test_list_payload_additive_fields(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(MAC, {"state": "awake", "held": True, "reason": "manual", "battery": 80, "on_ac": True,
                              "lid": "open"})
    row = _row(rig, MAC)
    for key, kind in (("device_id", str), ("name", str), ("state", str), ("held", bool), ("reason", str),
                      ("keep_awake", bool), ("timer_on", bool)):
        assert isinstance(row[key], kind), key
    assert row["battery"] == 80 and row["on_ac"] is True and row["lid"] == "open"


def test_mac_wake_still_pushes(tmp_path):
    rig = Rig(tmp_path)
    pushes = []
    rig.store._push = lambda token, env: pushes.append(token) or {"ok": True}
    rig.store.on_token(MAC, {"token": "ab12", "env": "development"})
    assert rig.store.wake(MAC) == {"ok": True, "pushed": True}
    assert pushes == ["ab12"] and rig.invokes == []


def test_lock_route(tmp_path, monkeypatch):
    from api import agents_routes
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)

    class C:
        mac_power = rig.store
    monkeypatch.setattr(agents_routes, "_core", lambda: C())
    status, body = agents_routes._v2("POST", "/agents/mac/lock", {}, {"device_id": PC})
    assert status == 200 and body["delivered"] is True


def test_pc_shows_asleep_once_it_says_so_even_with_the_socket_open(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    assert _row(rig, PC)["state"] == "awake"
    rig.store.on_sleeping(PC)                     # device_sleeping; the socket still looks open
    assert PC in rig.connected and _row(rig, PC)["state"] == "sleeping"
    rig.t += 30                                   # (a report seconds after the mark is its last one going down)
    rig.store.on_status(PC, PC_STATUS)            # reports in after waking
    assert _row(rig, PC)["state"] == "awake"


def test_pc_let_sleep_shows_asleep_at_once(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.store.let_sleep(PC)
    assert _row(rig, PC)["state"] == "sleeping"
    rig.store.sync(PC)                            # reconnects (hello)
    assert _row(rig, PC)["state"] == "awake"


def test_mac_sleep_mark_is_left_to_its_connection(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(MAC, {"state": "awake", "held": False, "reason": "", "battery": 80, "on_ac": True, "lid": "open"})
    rig.store.on_sleeping(MAC)
    assert _row(rig, MAC)["state"] == "awake"


def test_row_says_when_the_jarvis_app_isnt_running(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, {**PC_STATUS, "app": False})
    assert _row(rig, PC)["app_running"] is False and rig.store.app_down(PC) is True
    rig.store.on_status(PC, {**PC_STATUS, "app": True})
    assert _row(rig, PC)["app_running"] is True and rig.store.app_down(PC) is False
    rig.store.on_status(MAC, {"state": "awake", "held": False})
    assert _row(rig, MAC)["app_running"] is None and rig.store.app_down(MAC) is False


POD = "dev-pod"


def _pod_rig(tmp_path, connected):
    rig = Rig(tmp_path, connected=connected, skills={MAC: ["wol_send", "ui_look"], POD: ["wol_send", "pod_status"]})
    rig.store._os_of = lambda d: {PC: "windows"}.get(d, "macos")   # the Pod registers no platform: "macos"
    rig.store._name_of = lambda d: {MAC: "MacBook", PC: "Pranav-Desktop", POD: "Jarvis Pod"}.get(d, "")
    return rig


def test_wake_pc_prefers_the_always_on_pod(tmp_path):
    # Live 2026-11-18: only the Mac could send, and it sleeps too — Wake PC failed.
    rig = _pod_rig(tmp_path, connected={MAC, POD})
    rig.store.on_status(PC, PC_STATUS)
    out = rig.store.wake(PC)
    assert out == {"ok": True, "sent": True, "via": "Jarvis Pod"}
    assert rig.invokes == [(POD, "wol_send", {"mac": "aa:bb:cc:dd:ee:ff"})]


def test_wake_pc_falls_back_to_the_next_sender(tmp_path):
    rig = _pod_rig(tmp_path, connected={MAC, POD})
    sent = []
    rig.store._invoke = lambda d, s, a: (sent.append(d) or
                                         ({"ok": False, "error": "busy"} if d == POD else {"ok": True, "result": {"ok": True}}))
    rig.store.on_status(PC, PC_STATUS)
    assert rig.store.wake(PC) == {"ok": True, "sent": True, "via": "MacBook"} and sent == [POD, MAC]


def test_wake_pc_with_no_sender_awake_waits_for_the_macs_checkin(tmp_path):
    rig = _pod_rig(tmp_path, connected={PHONE})
    rig.store.on_status(MAC, {"state": "awake", "held": False})   # a known Mac, its wake timer on
    rig.store.on_status(PC, dict(PC_STATUS, wifi_ip="192.168.1.80"))
    out = rig.store.wake(PC)
    assert out == {"ok": True, "pending": True, "via": "MacBook", "within_min": 15}
    assert rig.invokes == [] and rig.store.device(PC)["wake_requested_at"] == rig.t
    answer = rig.store.checkin(MAC)
    assert answer["wol"] == [{"mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.1.80"}] and answer["wake"] is False
    rig.store.on_status(PC, PC_STATUS)                            # it woke: nothing more to send
    assert "wol" not in rig.store.checkin(MAC)


def test_a_pending_pc_wake_expires(tmp_path):
    rig = _pod_rig(tmp_path, connected={PHONE})
    rig.store.on_status(MAC, {"state": "awake", "held": False})
    rig.store.on_status(PC, PC_STATUS)
    rig.store.wake(PC)
    rig.t += 1300
    assert "wol" not in rig.store.checkin(MAC)


def test_a_mac_that_connects_sends_the_pending_pc_wake(tmp_path):
    rig = _pod_rig(tmp_path, connected={PHONE})
    rig.store._spawn = lambda fn: fn()
    rig.store.on_status(MAC, {"state": "awake", "held": False})
    rig.store.on_status(PC, PC_STATUS)
    rig.store.wake(PC)
    rig.connected.add(MAC)
    rig.store.sync(MAC)
    assert (MAC, "wol_send", {"mac": "aa:bb:cc:dd:ee:ff"}) in rig.invokes


def test_wake_pc_with_nothing_awake_waits_for_the_pcs_own_checkin(tmp_path):
    # His pick 2026-11-19: long sleeps drop the PC off Wi-Fi; it wakes itself every 15 minutes and asks.
    rig = Rig(tmp_path, connected={PHONE})
    rig.store.on_status(PC, dict(PC_STATUS, timer_on=True))
    out = rig.store.wake(PC)
    assert out == {"ok": True, "pending": True, "via": "the PC itself", "within_min": 15}
    assert rig.store.checkin(PC)["wake"] is True and "wol" not in rig.store.checkin(PC)


def test_a_sent_signal_that_never_arrives_is_still_picked_up_by_the_pcs_checkin(tmp_path):
    rig = Rig(tmp_path, connected={MAC})
    rig.store.on_status(PC, dict(PC_STATUS, timer_on=True))
    assert rig.store.wake(PC)["sent"] is True
    assert rig.store.checkin(PC)["wake"] is True



def test_a_pc_with_no_wifi_address_yet_still_waits_for_its_own_checkin(tmp_path):
    # Review: a slow first probe ("no Wi-Fi adapter found", no MAC) blocked even the timer fallback.
    rig = Rig(tmp_path, connected={PHONE})
    rig.store.on_status(PC, dict(PC_STATUS, wifi_mac="", wake={"capable": False, "adapter": "", "reason": "x"},
                                 timer_on=True))
    assert rig.store.wake(PC) == {"ok": True, "pending": True, "via": "the PC itself", "within_min": 15}


def _grant(rig, did=PC, days=1, **kw):
    g = {"id": "ab" * 16, "ts": int(rig.t), "until": int(rig.t + days * 86400), "device": did, "signature": "MEUCIQ=="}
    g.update(kw)
    return g


def test_an_unlock_permission_is_kept_handed_to_the_pc_and_shown(tmp_path):
    # His ask 2026-11-20: unlock without a Face ID every time — one signed permission, 30 days at most.
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    g = _grant(rig)
    assert rig.store.set_unlock_grant(PC, g) == {"ok": True, "until": g["until"]}
    assert rig.frames[-1] == (PC, {"type": "mac_unlock_grant", "grant": g})
    assert _row(rig, PC)["unlock_grant_until"] == g["until"]
    rig.frames.clear()
    rig.store.sync(PC)                                         # a jc-client that reconnects gets it again
    assert (PC, {"type": "mac_unlock_grant", "grant": g}) in rig.frames


def test_a_bad_or_too_long_permission_is_refused(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    for bad in (_grant(rig, days=31), _grant(rig, days=-1), _grant(rig, device=MAC), _grant(rig, id="xyz"),
                _grant(rig, ts=int(rig.t + 3600)), _grant(rig, signature="")):
        assert rig.store.set_unlock_grant(PC, bad)["ok"] is False
    assert "unlock_grant_until" not in _row(rig, PC) or _row(rig, PC)["unlock_grant_until"] is None


def test_stopping_the_permission_tells_the_pc(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    g = _grant(rig)
    rig.store.set_unlock_grant(PC, g)
    assert rig.store.revoke_unlock_grant(PC) == {"ok": True}
    assert rig.frames[-1] == (PC, {"type": "mac_unlock_grant", "revoke": g["id"]})
    assert _row(rig, PC)["unlock_grant_until"] is None


def test_an_expired_permission_is_gone(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(PC, PC_STATUS)
    rig.store.set_unlock_grant(PC, _grant(rig))
    rig.t += 2 * 86400
    assert _row(rig, PC)["unlock_grant_until"] is None
