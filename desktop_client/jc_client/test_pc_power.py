"""PC power (spec §6b): the PC reports like the Mac (mac_power_status), obeys mac_power_set
(keep awake, sleep, lock), answers the app's mac_power_state, and wol_send wakes a PC."""
import pytest

from jc_client import pc_power
from jc_client.pc_power import PcPower

WIFI = {"name": "Wi-Fi", "description": "Intel(R) Wi-Fi 6E AX211 160MHz", "mac": "AA-BB-CC-DD-EE-FF", "magic": "1"}
DEVQUERY = "HID Keyboard Device\nIntel(R) Wi-Fi 6E AX211 160MHz\nHID-compliant mouse\n"


class Rig:
    def __init__(self, wifi=WIFI, devquery=DEVQUERY):
        self.sent, self.states, self.locks, self.suspends = [], [], [], []
        self.power = PcPower(lambda f: self.sent.append(f) or True,
                             set_state=lambda flags: self.states.append(flags) or 1,
                             lock=lambda: self.locks.append(1), suspend=lambda: self.suspends.append(1),
                             probe=lambda: pc_power.probe(lambda: devquery, lambda: wifi),
                             battery=lambda: (None, None), lan_ip=lambda: "192.168.1.80")


def test_keep_awake_flags():
    rig = Rig()
    rig.power.keep_awake(True)
    rig.power.keep_awake(False)
    assert rig.states == [0x80000001, 0x80000000]


def test_status_event_shape():
    rig = Rig()
    ev = rig.power.status_event()
    assert ev["type"] == "event" and ev["name"] == "mac_power_status"
    assert set(ev["data"]) == {"os", "state", "held", "reason", "keep_awake", "timer_on", "battery", "on_ac",
                               "lid", "wifi_mac", "wifi_ip", "wake"}
    d = ev["data"]
    assert d["os"] == "windows" and d["state"] == "awake" and d["wifi_mac"] == "aa:bb:cc:dd:ee:ff"
    assert d["wifi_ip"] == "192.168.1.80"
    assert d["wake"] == {"capable": True, "adapter": "Intel(R) Wi-Fi 6E AX211 160MHz", "reason": ""}


def test_keep_awake_shows_as_held_manual():
    rig = Rig()
    rig.power.handle_frame({"type": "mac_power_set", "keep_awake": True})
    d = rig.sent[-1]["data"]
    assert d["held"] is True and d["reason"] == "manual" and d["keep_awake"] is True


def test_wake_capability_not_listed():
    cap = pc_power.wake_capability(lambda: "HID Keyboard Device\n", lambda: WIFI)
    assert cap == {"capable": False, "adapter": WIFI["description"], "reason": "this Wi-Fi adapter can't wake the PC"}


def test_wake_capability_magic_packet_off():
    cap = pc_power.wake_capability(lambda: DEVQUERY, lambda: dict(WIFI, magic="0"))
    assert cap["capable"] is False and "magic packet" in cap["reason"]


def test_wake_capability_no_wifi():
    cap = pc_power.wake_capability(lambda: DEVQUERY, lambda: None)
    assert cap["capable"] is False and cap["adapter"] == ""


def test_on_set_lock_calls_lockworkstation():
    rig = Rig()
    rig.power.handle_frame({"type": "mac_power_set", "lock": True})
    assert rig.locks == [1] and rig.suspends == []


def test_on_set_let_sleep_suspends_after_keep_awake_off():
    rig = Rig()
    rig.power.keep_awake(True)
    rig.power.handle_frame({"type": "mac_power_set", "let_sleep": True})
    assert rig.states[-1] == 0x80000000 and rig.suspends == [1]


def test_unknown_keys_ignored():
    rig = Rig()
    rig.power.handle_frame({"type": "mac_power_set", "timer_on": False, "zzz": 1})
    assert rig.locks == [] and rig.suspends == []


def test_app_link_requests():
    rig = Rig()
    state = rig.power.ui_request({"type": "mac_power_state"})
    assert state["ok"] is True and state["os"] == "windows" and state["wake"]["capable"] is True
    out = rig.power.ui_request({"type": "mac_power_set", "keep_awake": True})
    assert out["ok"] is True and rig.states[-1] == 0x80000001
    assert "mac_power_state" in PcPower.UI_REQUESTS and "mac_power_set" in PcPower.UI_REQUESTS


def test_on_connected_sends_status():
    rig = Rig()
    rig.power.on_connected()
    assert rig.sent[-1]["name"] == "mac_power_status"


def test_magic_packet_bytes():
    assert pc_power.magic_packet("aa:bb:cc:dd:ee:ff") == b"\xff" * 6 + bytes.fromhex("aabbccddeeff") * 16
    assert pc_power.magic_packet("AA-BB-CC-DD-EE-FF") == pc_power.magic_packet("aa:bb:cc:dd:ee:ff")


def test_magic_packet_rejects_bad_mac():
    with pytest.raises(ValueError):
        pc_power.magic_packet("aa:bb:cc")


def test_wol_send_skill(monkeypatch):
    from jc_client import skills
    skills.load_all()
    sent = []

    class Sock:
        def __init__(self, *a):
            pass

        def setsockopt(self, *a):
            pass

        def sendto(self, data, addr):
            sent.append((data, addr))

        def close(self):
            pass

    monkeypatch.setattr(pc_power.socket, "socket", Sock)
    out = skills.invoke("wol_send", {"mac": "aa:bb:cc:dd:ee:ff"})
    assert out == {"ok": True, "sent_to": "255.255.255.255:9, 255.255.255.255:7"}
    assert sent and sent[0][1] == ("255.255.255.255", 9) and len(sent[0][0]) == 102
    assert len(sent) == 6   # each target three times
    assert skills.invoke("wol_send", {"mac": "nope"}) == {"ok": False, "error": "bad MAC address"}

    # With the PC's address it also goes straight to it and to its subnet's broadcast.
    sent.clear()
    out = skills.invoke("wol_send", {"mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.1.80"})
    assert out["ok"] is True
    assert {a for _, a in sent} == {(h, p) for h in ("255.255.255.255", "192.168.1.80", "192.168.1.255") for p in (9, 7)}
    assert len(sent) == 18
    sent.clear()
    skills.invoke("wol_send", {"mac": "aa:bb:cc:dd:ee:ff", "ip": "not an ip"})
    assert {a[0] for _, a in sent} == {"255.255.255.255"}


def test_service_routes_app_power_requests_to_pc_power(monkeypatch):
    from jc_client import service
    svc = service.Service()
    rig = Rig()
    svc._power = rig.power
    out = svc._ui_request({"type": "mac_power_set", "keep_awake": True})
    assert out["ok"] is True and out["keep_awake"] is True
    svc._handle_frame(None, {"type": "mac_power_set", "lock": True})
    import time
    for _ in range(50):
        if rig.locks:
            break
        time.sleep(0.02)
    assert rig.locks == [1]



def test_keep_awake_is_held_and_released_by_one_thread():
    """Review 2026-11-15: SetThreadExecutionState is per thread, so the same thread must set and clear it."""
    import threading
    seen = []
    p = PcPower(lambda f: True, set_state=lambda flags: seen.append((flags, threading.get_ident())) or 1,
                lock=lambda: None, suspend=lambda: None, probe=lambda: ({}, ""), battery=lambda: (None, None))
    threading.Thread(target=lambda: p.keep_awake(True)).start()
    import time
    for _ in range(100):
        if seen:
            break
        time.sleep(0.01)
    t = threading.Thread(target=lambda: p.keep_awake(False))
    t.start()
    t.join(3)
    assert [f for f, _ in seen] == [0x80000001, 0x80000000]
    assert seen[0][1] == seen[1][1]


# ── Unlock PC (the Mac's "Unlock Mac" flow) ─────────────────────────────────────
def _unlock_rig(app_pid_ok=True):
    sent, ui = [], []
    power = PcPower(lambda f: sent.append(f) or True, set_state=lambda f: 1, lock=lambda: None,
                    suspend=lambda: None, probe=lambda: ({}, ""), battery=lambda: (None, None),
                    lan_ip=lambda: "", ui_broadcast=ui.append, is_app=lambda pid: app_pid_ok and pid == 4242)
    return power, sent, ui


def _wait_for(pred, timeout=3.0):
    import time
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False


def test_unlock_asks_his_iphone_then_the_app():
    power, sent, ui = _unlock_rig()
    power.handle_frame({"type": "mac_password_unlock"})
    assert _wait_for(lambda: any(f.get("name") == "mac_password_request" for f in sent))
    req = next(f["data"] for f in sent if f.get("name") == "mac_password_request")
    assert req["kind"] == "unlock" and req["context"] == "Unlock PC" and req["nonce"]
    # A second press while one is waiting doesn't ask twice.
    power.handle_frame({"type": "mac_password_unlock"})
    power.handle_frame({"type": "mac_password_answer", "id": req["id"], "decision": "allow", "ts": 1, "signature": "sig"})
    assert _wait_for(lambda: any(m.get("type") == "password_fill" for m in ui))
    fill = next(m for m in ui if m.get("type") == "password_fill")
    assert fill["kind"] == "unlock" and fill["context"] == "Unlock PC" and fill["proof"] == {"ts": 1, "signature": "sig"}
    # Only the installed app may answer.
    assert power.ui_request({"type": "password_fill_result", "request_id": req["id"], "ok": True, "_peer_pid": 7}) \
        == {"ok": False, "error": "not the Jarvis app"}
    assert power.ui_request({"type": "password_fill_result", "request_id": req["id"], "ok": True, "_peer_pid": 4242}) == {"ok": True}
    assert _wait_for(lambda: any(f.get("name") == "mac_password_done" for f in sent))
    done = next(f["data"] for f in sent if f.get("name") == "mac_password_done")
    assert done == {"id": req["id"], "ok": True}
    assert sum(1 for f in sent if f.get("name") == "mac_password_request") == 1


def test_unlock_denied_never_reaches_the_app():
    power, sent, ui = _unlock_rig()
    power.handle_frame({"type": "mac_password_unlock"})
    assert _wait_for(lambda: any(f.get("name") == "mac_password_request" for f in sent))
    req = next(f["data"] for f in sent if f.get("name") == "mac_password_request")
    power.handle_frame({"type": "mac_password_answer", "id": req["id"], "decision": "deny", "ts": 1, "signature": "x"})
    assert _wait_for(lambda: any(f.get("name") == "mac_password_done" for f in sent))
    assert not any(m.get("type") == "password_fill" for m in ui)


def test_service_routes_every_power_frame_the_module_handles():
    """The service only forwards POWER_FRAMES to PcPower; a handled type missing there is silently dropped
    ("unknown frame type"), which is how Remote Desktop's Face ID request once never reached the phone."""
    import inspect
    import re
    from jc_client import pc_power
    from jc_client.service import POWER_FRAMES
    handled = set(re.findall(r't == "([a-z_]+)"', inspect.getsource(pc_power.PcPower.handle_frame)))
    assert "rdp_credential_request" in POWER_FRAMES
    assert handled <= set(POWER_FRAMES), handled - set(POWER_FRAMES)


# ── live 2026-11-17: Sleep flipped back to Awake; a Sleep pressed while asleep ran on the next wake ──

def test_let_sleep_sends_no_awake_report_on_its_way_down():
    rig = Rig()
    rig.power.handle_frame({"type": "mac_power_set", "let_sleep": True})
    assert rig.suspends == [1]
    assert not [f for f in rig.sent if isinstance(f, dict) and f.get("name") == "mac_power_status"]


def test_old_sleep_and_lock_commands_are_dropped():
    import time
    rig = Rig()
    stale = time.time() - 60          # queued while the PC slept, delivered when it woke
    rig.power.handle_frame({"type": "mac_power_set", "let_sleep": True, "ts": stale})
    rig.power.handle_frame({"type": "mac_power_set", "lock": True, "ts": stale})
    assert rig.suspends == [] and rig.locks == []
    rig.power.handle_frame({"type": "mac_power_set", "lock": True, "ts": time.time()})
    rig.power.handle_frame({"type": "mac_power_set", "lock": True})      # an older server sends no ts
    assert rig.locks == [1, 1]


def test_status_says_whether_the_jarvis_app_is_linked():
    linked = {"v": False}
    p = PcPower(lambda f: True, set_state=lambda f: 1, lock=lambda: None, suspend=lambda: None,
                probe=lambda: pc_power.probe(lambda: DEVQUERY, lambda: WIFI), battery=lambda: (None, None),
                lan_ip=lambda: "", app_linked=lambda: linked["v"])
    assert p.status()["app"] is False
    linked["v"] = True
    assert p.status()["app"] is True
    assert "app" not in Rig().power.status()    # nothing to say: no key (the server keeps today's view)
