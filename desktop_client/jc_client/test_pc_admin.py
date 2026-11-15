"""PC admin actions (contract C6): phone Face ID first, then Windows' own UAC prompt."""
import re
import threading
import time

from jc_client import pc_admin, service
from jc_client.pc_admin import PcAdmin


class Up:
    def __init__(self, online=True):
        self.online = online
        self.frames = []

    def __call__(self, frame):
        self.frames.append(frame)
        return self.online


def _decide_later(admin, up, approved, delay=0.05):
    def go():
        for _ in range(100):
            if up.frames:
                break
            time.sleep(0.01)
        time.sleep(delay)
        admin.decision({"type": "pc_admin_decision", "request_id": up.frames[0]["data"]["request_id"],
                        "approved": approved})
    threading.Thread(target=go, daemon=True).start()


def test_request_frame_shape():
    up = Up()
    admin = PcAdmin(up, lambda c: 42, timeout=0.2)
    admin.request("winget install foo", "install foo", "dev1")
    f = up.frames[0]
    assert f["type"] == "event" and f["name"] == "pc_admin_request"
    assert set(f["data"]) == {"request_id", "command", "why"}
    assert re.fullmatch(r"[0-9a-f]{32}", f["data"]["request_id"])
    assert f["data"]["command"] == "winget install foo" and f["data"]["why"] == "install foo"


def test_admin_run_approved_elevates():
    up, ran = Up(), []
    admin = PcAdmin(up, lambda c: ran.append(c) or 42, timeout=3)
    _decide_later(admin, up, True)
    assert admin.request("winget install foo", "why", "dev1") == {"ok": True, "status": "approved"}
    assert ran == ["winget install foo"]


def test_admin_run_elevation_refused_reports_error():
    up = Up()
    admin = PcAdmin(up, lambda c: 5, timeout=3)   # ShellExecute ≤ 32 = failed / UAC cancelled
    _decide_later(admin, up, True)
    out = admin.request("x", "why", "dev1")
    assert out["ok"] is False and out["status"] == "approved" and "elevat" in out["error"]


def test_admin_run_denied_never_elevates():
    up, ran = Up(), []
    admin = PcAdmin(up, lambda c: ran.append(c) or 42, timeout=3)
    _decide_later(admin, up, False)
    assert admin.request("x", "why", "dev1") == {"ok": False, "status": "denied"}
    assert ran == []


def test_admin_run_timeout_is_denied():
    ran = []
    admin = PcAdmin(Up(), lambda c: ran.append(c) or 42, timeout=0.2)
    assert admin.request("x", "why", "dev1") == {"ok": False, "status": "timeout"}
    assert ran == []


def test_admin_run_offline_denies_immediately():
    admin = PcAdmin(Up(online=False), lambda c: 42, timeout=5)
    t = time.monotonic()
    assert admin.request("x", "why", "dev1") == {"ok": False, "status": "denied", "error": "offline"}
    assert time.monotonic() - t < 0.1


def test_unknown_request_id_ignored():
    admin = PcAdmin(Up(), lambda c: 42, timeout=0.1)
    admin.decision({"type": "pc_admin_decision", "request_id": "nope", "approved": True})


def test_empty_command_refused():
    up = Up()
    admin = PcAdmin(up, lambda c: 42, timeout=1)
    assert admin.request("  ", "why", "dev1") == {"ok": False, "status": "denied", "error": "no command"}
    assert up.frames == []


def test_platform_name():
    assert pc_admin.platform_name("darwin") == "macos"
    assert pc_admin.platform_name("win32") == "windows"
    assert pc_admin.platform_name("linux") == "linux"


def test_ui_hello_has_platform_and_game_mode():
    hello = service.Service()._ui_hello()
    assert hello["platform"] in ("macos", "windows", "linux")
    assert hello["game_mode"] == {"on": False, "reason": "", "anticheat": False}


def test_admin_run_request_off_windows_is_denied(monkeypatch):
    monkeypatch.setattr(service.sys, "platform", "darwin")
    out = service.Service()._ui_request({"type": "admin_run", "command": "x", "why": "y"})
    assert out == {"ok": False, "status": "denied", "error": "windows only"}


def test_admin_run_does_not_hold_up_other_app_requests(tmp_path):
    """admin_run waits on Face ID: the app's next request still gets its reply at once."""
    import json as _json
    from jc_client.ui_server import UiServer
    from jc_client.unix_server import connect

    def on_request(req):
        if req.get("type") == "admin_run":
            time.sleep(1.0)
            return {"ok": True, "status": "approved"}
        return {"ok": True}

    srv = UiServer(str(tmp_path / "ui.sock"), hello=lambda: {}, on_request=on_request)
    srv.mode = "tcp"
    srv.start()
    try:
        s = connect(srv.path, 2)
        s.settimeout(3)
        s.sendall(b'{"type":"admin_run","id":1,"command":"x"}\n{"type":"ping","id":2}\n')
        got, buf, t0 = [], b"", time.monotonic()
        while len(got) < 3:
            buf += s.recv(65536)
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                got.append((_json.loads(line), time.monotonic() - t0))
        replies = [(m["id"], t) for m, t in got if m.get("type") == "reply"]
        assert replies[0][0] == 2 and replies[0][1] < 0.5
        assert replies[1][0] == 1
        s.close()
    finally:
        srv.close()


def test_is_jarvis_app_checks_the_whole_installed_path():
    local = r"C:\Users\Pranav K\AppData\Local"
    want = pc_admin.app_exe_path(local)
    good = r"C:\Users\Pranav K\AppData\Local\Programs\Jarvis\app\Jarvis.exe"
    assert want == good
    assert pc_admin.is_jarvis_app(42, lambda p: good.lower(), expected=want)       # case-insensitive
    assert not pc_admin.is_jarvis_app(42, lambda p: r"C:\Windows\System32\cmd.exe", expected=want)
    # Review 2026-11-15: a copy under another folder ending the same way must not pass.
    fake = r"C:\Users\Pranav K\AppData\Local\Temp\Programs\Jarvis\app\Jarvis.exe"
    assert not pc_admin.is_jarvis_app(42, lambda p: fake, expected=want)
    assert not pc_admin.is_jarvis_app(0, lambda p: good, expected=want)
    assert not pc_admin.is_jarvis_app(42, lambda p: (_ for _ in ()).throw(OSError("gone")), expected=want)
    assert not pc_admin.is_jarvis_app(42, lambda p: good, expected="")


def test_admin_run_from_a_stranger_is_denied(monkeypatch):
    monkeypatch.setattr(service.sys, "platform", "win32")
    monkeypatch.setattr(pc_admin, "is_jarvis_app", lambda pid, exe_of=None: False)
    out = service.Service()._ui_request({"type": "admin_run", "command": "x", "why": "y", "_peer_pid": 9})
    assert out == {"ok": False, "status": "denied", "error": "only the Jarvis app may ask"}
