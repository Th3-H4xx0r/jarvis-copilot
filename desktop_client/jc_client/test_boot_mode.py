"""Jarvis on the PC before sign-in (spec 2026-11-23-pc-boot-client): a boot-time jc-client holds the link at the
sign-in screen, offers only desktop-free skills, signs him in through the JarvisUnlock service, and steps aside
once his Windows session exists."""
import json

import pytest

from jc_client import boot_mode, helper_pipe, pc_power
from jc_client.pc_power import PcPower


@pytest.fixture
def boot(monkeypatch):
    monkeypatch.setenv(boot_mode.ENV, "1")


def _power():
    return PcPower(lambda f: True, set_state=lambda flags: 1, lock=lambda: None, suspend=lambda: None,
                   probe=lambda: ({"capable": True, "adapter": "x", "reason": ""}, "aa:bb:cc:dd:ee:ff"),
                   battery=lambda: (None, None), lan_ip=lambda: "192.168.1.80", run=lambda argv, timeout=15.0: "")


def test_is_boot_reads_the_env(monkeypatch):
    monkeypatch.delenv(boot_mode.ENV, raising=False)
    assert boot_mode.is_boot() is False
    monkeypatch.setenv(boot_mode.ENV, "1")
    assert boot_mode.is_boot() is True


def test_boot_skills_filter():
    manifest = [{"name": "ui_look"}, {"name": "screen_locked"}, {"name": "wol_send"}, {"name": "open_app"}]
    assert [m["name"] for m in boot_mode.filter_manifest(manifest)] == ["screen_locked", "wol_send"]


def test_user_signed_in_from_sessions():
    assert boot_mode.user_signed_in("krish", sessions=lambda: [(0, ""), (1, "krish")]) is True
    assert boot_mode.user_signed_in("krish", sessions=lambda: [(0, ""), (1, "")]) is False   # sign-in screen
    assert boot_mode.user_signed_in("KRISH", sessions=lambda: [(3, "krish")]) is True       # e.g. a Remote Desktop one


def test_handover_exits_when_he_signs_in():
    state, exits = {"in": False}, []
    h = boot_mode.Handover("krish", sessions=lambda: [(1, "krish")] if state["in"] else [(1, "")],
                           exit=lambda: exits.append(1))
    assert h.tick() is False and exits == []
    state["in"] = True
    assert h.tick() is True and exits == [1]


def test_normal_start_stops_a_boot_instance(tmp_path):
    pid_file = tmp_path / "boot.pid"
    pid_file.write_text("4242")
    killed = []
    stopped = boot_mode.stop_boot_instance(pid_file, is_running=lambda pid: pid == 4242 and not killed,
                                           kill=lambda pid: killed.append(pid), wait_s=0.5)
    assert stopped is True and killed == [4242] and not pid_file.exists()


def test_no_boot_instance_nothing_to_stop(tmp_path):
    assert boot_mode.stop_boot_instance(tmp_path / "none.pid", is_running=lambda pid: False,
                                        kill=lambda pid: None) is False


def test_status_reason_signed_out(boot):
    st = _power().status()
    assert st["state"] == "awake" and st["reason"] == "signed_out"


def test_boot_unlock_goes_to_the_helper_pipe(boot, monkeypatch):
    sent = []
    monkeypatch.setattr(helper_pipe, "signin", lambda msg, timeout: sent.append(msg) or {"ok": True})
    out = _power()._ask_app({"type": "password_fill", "id": "r1", "kind": "unlock", "context": "c", "nonce": "n",
                             "proof": {"ts": 1795000000, "signature": "sig"}, "device": "pc-1"}, 30)
    assert out["ok"] is True
    assert sent == [{"kind": "unlock", "context": "c", "nonce": "n", "proof": {"ts": 1795000000, "signature": "sig"},
                     "device": "pc-1"}]


def test_boot_unlock_error_is_passed_on(boot, monkeypatch):
    monkeypatch.setattr(helper_pipe, "signin", lambda msg, timeout: {"ok": False, "error": "no copy"})
    out = _power()._ask_app({"type": "password_fill", "id": "r1", "kind": "unlock"}, 30)
    assert out == {"ok": False, "error": "no copy"}


class FakePipe:
    def __init__(self, reply):
        self.reply, self.written = reply, b""

    def write(self, data):
        self.written += data

    def read(self, n=-1):
        out, self.reply = self.reply, b""
        return out

    def close(self):
        pass


def test_helper_pipe_signin_round_trip():
    pipe = FakePipe(b'{"ok": true}\n')
    out = helper_pipe.signin({"kind": "unlock", "nonce": "n"}, 30, opener=lambda path: pipe)
    assert out["ok"] is True
    assert json.loads(pipe.written.decode()) == {"signin": {"kind": "unlock", "nonce": "n"}}


def test_screen_locked_in_boot_mode(boot):
    from jc_client.skills import common
    out = common.screen_locked()
    assert out["locked"] is True and out["signed_out"] is True



# ── cli: start --boot, and the normal start taking over ──
def test_boot_start_steps_aside_when_he_is_signed_in(monkeypatch, tmp_path):
    from jc_client import cli
    ran = []
    monkeypatch.setattr(cli, "BOOT_PID_FILE", tmp_path / "boot.pid")
    monkeypatch.setattr(boot_mode, "user_signed_in", lambda *a, **k: True)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False: ran.append(1) or 0)
    monkeypatch.delenv(boot_mode.ENV, raising=False)

    class A:
        no_tray, boot, verbose = True, True, False
    assert cli.cmd_start(A()) == 0 and ran == []


def test_boot_start_runs_at_the_sign_in_screen(monkeypatch, tmp_path):
    from jc_client import cli
    ran, watched = [], []
    monkeypatch.setattr(cli, "BOOT_PID_FILE", tmp_path / "boot.pid")
    monkeypatch.setattr(cli, "PID_FILE", tmp_path / "jc.pid")
    monkeypatch.setattr(boot_mode, "user_signed_in", lambda *a, **k: False)
    monkeypatch.setattr(boot_mode, "watch", lambda pid_file=None: watched.append(pid_file))
    monkeypatch.setattr(cli.service, "run", lambda verbose=False: ran.append(boot_mode.is_boot()) or 0)
    monkeypatch.delenv(boot_mode.ENV, raising=False)

    class A:
        no_tray, boot, verbose = True, True, False
    assert cli.cmd_start(A()) == 0 and ran == [True] and watched == [tmp_path / "boot.pid"]


def test_normal_start_takes_over_from_boot(monkeypatch, tmp_path):
    from jc_client import cli
    stops = []
    monkeypatch.setattr(cli, "PID_FILE", tmp_path / "jc.pid")
    monkeypatch.setattr(boot_mode, "stop_boot_instance", lambda *a, **k: stops.append(1) or True)
    monkeypatch.setattr(cli.service, "run", lambda verbose=False: 0)

    class A:
        no_tray, boot, verbose = True, False, False
    assert cli.cmd_start(A()) == 0 and stops == [1]



def test_boot_task_script_shape():
    from jc_client import cli
    ps = cli._boot_task_ps(r"C:\\Users\\krish\\AppData\\Local\\Programs\\jc-client\\.venv\\Scripts\\jc-client.exe")
    assert "-AtStartup" in ps and "-LogonType S4U" in ps
    assert "-TaskName 'jc-client-boot'" in ps and "-TaskPath '\\JarvisCopilot\\'" in ps
    assert "start --no-tray --boot" in ps and "jc-client.exe" in ps
    assert "RepetitionInterval" in ps          # the 5-minute watchdog brings it back after a crash or sign-out



# ── live 2026-11-23: the boot client said "not paired" (Credential Manager is unreadable before sign-in) ──
def _creds_rig(monkeypatch, tmp_path):
    from jc_client import credentials as C
    cfg = tmp_path / "config.yaml"
    cfg.write_text(json.dumps({"server_url": "https://jarvis.example", "cert_fingerprint": "ab:cd", "device_id": "pc-1"}))
    monkeypatch.setattr(C, "_CONFIG_FILE", cfg)
    monkeypatch.setattr(C, "_BOOT_COPY", tmp_path / "boot-session.bin")
    monkeypatch.setattr(C, "_try_keyring_get", lambda: None)            # what S4U sees
    monkeypatch.setattr(C, "_try_keyring_get_user", lambda user: None)
    return C


def test_boot_load_falls_back_to_the_boot_copy(monkeypatch, tmp_path):
    C = _creds_rig(monkeypatch, tmp_path)
    C.save_boot_copy(C.Credentials(cookie="cookie-1", cf_client_secret="secret-1"))
    monkeypatch.setenv(boot_mode.ENV, "1")
    creds = C.load()
    assert creds.cookie == "cookie-1" and creds.cf_client_secret == "secret-1" and creds.paired


def test_normal_load_falls_back_to_the_copy_too(monkeypatch, tmp_path):
    # Live 2026-11-23: after a restart Credential Manager had lost the session even in his own session, and the
    # client sat on "reconnecting". The copy keeps it online, and the session goes back into Credential Manager.
    C = _creds_rig(monkeypatch, tmp_path)
    C.save_boot_copy(C.Credentials(cookie="cookie-1", cf_client_secret="secret-1"))
    put = []
    monkeypatch.setattr(C, "_try_keyring_set", lambda v: put.append(("session", v)) or True)
    monkeypatch.setattr(C, "_try_keyring_set_user", lambda u, v: put.append((u, v)) or True)
    monkeypatch.delenv(boot_mode.ENV, raising=False)
    creds = C.load()
    assert creds.cookie == "cookie-1" and creds.paired
    assert ("session", "cookie-1") in put


def test_refresh_boot_copy_only_when_paired(monkeypatch, tmp_path):
    C = _creds_rig(monkeypatch, tmp_path)
    monkeypatch.setattr(C, "load", lambda: C.Credentials())
    assert C.refresh_boot_copy() is False and not (tmp_path / "boot-session.bin").exists()
    monkeypatch.setattr(C, "load", lambda: C.Credentials(server_url="https://j", cookie="c", cert_fingerprint="f"))
    assert C.refresh_boot_copy() is True and C.load_boot_copy()["cookie"] == "c"
