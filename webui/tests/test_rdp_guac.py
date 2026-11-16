"""The web's Remote Desktop gateway (plan 2026-11-15-remote-desktop, Task 4): a Guacamole WebSocket
tunnel to a local guacd. The server does the handshake with the session's in-memory password, the
browser never sees it; only an approved web session opens it; a refused password reads as his
message; the per-session drive folder goes when the session ends; off closes tunnels at once."""
from __future__ import annotations

import os
import queue
import socket
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api import rdp_guac  # noqa: E402
from api.rdp_guac import guac_encode, guac_parse  # noqa: E402
from api.rdp_sessions import RdpSessions  # noqa: E402

READY = {"edition": "Windows 11 Pro", "rdp_enabled": True, "firewall_scoped": True,
         "username": "MicrosoftAccount\\krish@example.com", "tailscale_ip": "100.119.223.124", "idle_s": 900.0,
         "locked": True, "game": None, "remote_session": False, "has_password": True}
ARGS = ["VERSION_1_5_0", "hostname", "port", "domain", "username", "password", "width", "height", "dpi",
        "security", "ignore-cert", "resize-method", "enable-drive", "drive-name", "drive-path",
        "create-drive-path", "enable-audio-input", "color-depth", "disable-audio"]


# ── protocol helpers ────────────────────────────────────────────────────────
def test_guac_encode_parse_roundtrip():
    assert guac_encode("select", "rdp") == "6.select,3.rdp;"
    assert guac_encode("nop") == "3.nop;"
    # lengths count code points, not bytes: é is 1, 😀 is 1
    assert guac_encode("name", "café😀") == "4.name,5.café😀;"
    text = guac_encode("size", "1600", "900", "96") + guac_encode("key", "a;b,c", "1") + guac_encode("", "ping", "1")
    assert guac_parse(text) == [["size", "1600", "900", "96"], ["key", "a;b,c", "1"], ["", "ping", "1"]]
    # an incomplete tail isn't an instruction yet
    assert guac_parse("4.sync,3.123;5.mou") == [["sync", "123"]]


def test_stream_parser_finds_whole_instructions_across_chunks():
    p = rdp_guac.GuacStream()
    whole = guac_encode("img", "1", "14", "0", "image/png", "0", "0") + guac_encode("blob", "1", "AAA;,")
    out = []
    for i in range(0, len(whole), 5):           # arbitrary chunk boundaries, even inside elements
        out += p.feed(whole[i:i + 5])
    assert "".join(raw for _, raw in out) == whole
    assert [ins for ins, _ in out] == [["img", "1", "14", "0", "image/png", "0", "0"], ["blob", "1", "AAA;,"]]


# ── a fake guacd and a fake browser ─────────────────────────────────────────
class FakeGuacd:
    def __init__(self, after_ready=None):
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(4)
        self.addr = self.srv.getsockname()
        self.got = []            # instructions received
        self.after_ready = after_ready or []
        self.conn = None
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        try:
            conn, _ = self.srv.accept()
        except OSError:
            return
        self.conn = conn
        p = rdp_guac.GuacStream()
        while True:
            try:
                data = conn.recv(65536)
            except OSError:
                return
            if not data:
                return
            for ins, _ in p.feed(data.decode()):
                self.got.append(ins)
                if ins[0] == "select":
                    conn.sendall(guac_encode("args", *ARGS).encode())
                elif ins[0] == "connect":
                    conn.sendall(guac_encode("ready", "$conn-1").encode())
                    for extra in self.after_ready:
                        conn.sendall(extra.encode())
                elif ins[0] == "key":
                    conn.sendall(guac_encode("sync", "42").encode())

    def close(self):
        try:
            self.srv.close()
            if self.conn:
                self.conn.close()
        except OSError:
            pass


class FakeBrowser:
    """The tunnel's browser side: recv() gives the browser's text messages, send() collects ours."""

    def __init__(self):
        self.inbox = queue.Queue()
        self.sent = []
        self.closed = threading.Event()

    def recv(self):
        while not self.closed.is_set():
            try:
                return self.inbox.get(timeout=0.05)
            except queue.Empty:
                continue
        return None

    def send(self, text):
        if self.closed.is_set():
            raise OSError("closed")
        self.sent.append(text)

    def close(self):
        self.closed.set()

    def instructions(self):
        return guac_parse("".join(self.sent))


@pytest.fixture()
def store(tmp_path):
    s = RdpSessions(send_frame=lambda d, f: True, settings=lambda: {}, device_name=lambda d: "pranav-computer")
    s.put_status("pc-1", dict(READY))
    return s


def _approved_web(store):
    sid = store.create("pc-1", "web", True, None)["session"]["id"]
    store.on_credential("pc-1", {"session_id": sid, "ok": True, "credential": {"password": "S3cret;pw"}})
    return sid


def _run(store, sid, guacd, tmp_path, w=1600, h=900, dpi=96):
    browser = FakeBrowser()
    sess, err = rdp_guac.admit(sid, store)
    assert sess is not None, err
    t = threading.Thread(target=rdp_guac.run, args=(sess, browser, store),
                         kwargs={"guacd": guacd.addr, "width": w, "height": h, "dpi": dpi,
                                 "drive_root": tmp_path / "drive"}, daemon=True)
    t.start()
    return browser, t


def _wait(cond, timeout=2.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def test_handshake_args_exact(store, tmp_path):
    guacd = FakeGuacd()
    sid = _approved_web(store)
    browser, t = _run(store, sid, guacd, tmp_path)
    assert _wait(lambda: any(i[0] == "connect" for i in guacd.got))
    ops = [i[0] for i in guacd.got]
    assert ops[:6] == ["select", "size", "audio", "video", "image", "connect"]
    assert guacd.got[0] == ["select", "rdp"]
    assert guacd.got[1] == ["size", "1600", "900", "96"]
    assert guacd.got[2] == ["audio", "audio/L16"]
    assert guacd.got[3] == ["video"]
    assert guacd.got[4] == ["image", "image/png", "image/jpeg", "image/webp"]
    connect = dict(zip(ARGS, guacd.got[5][1:]))
    drive = str(tmp_path / "drive" / sid)
    assert connect == {
        "VERSION_1_5_0": "VERSION_1_5_0", "hostname": "100.119.223.124", "port": "3389", "domain": "",
        "username": "MicrosoftAccount\\krish@example.com", "password": "S3cret;pw", "width": "1600",
        "height": "900", "dpi": "96", "security": "nla", "ignore-cert": "true",
        "resize-method": "display-update", "enable-drive": "true", "drive-name": "Jarvis", "drive-path": drive,
        "create-drive-path": "true", "enable-audio-input": "false", "color-depth": "24", "disable-audio": ""}
    # the browser gets the tunnel id first, and never the password
    assert _wait(lambda: browser.sent)
    assert browser.instructions()[0][0] == "" and len(browser.instructions()[0]) == 2
    assert "S3cret" not in "".join(browser.sent)
    browser.close()
    t.join(timeout=2)
    guacd.close()


def test_tunnel_pumps_and_answers_pings(store, tmp_path):
    guacd = FakeGuacd()
    sid = _approved_web(store)
    browser, t = _run(store, sid, guacd, tmp_path)
    assert _wait(lambda: browser.sent)
    browser.inbox.put(guac_encode("", "ping", "1234"))        # the JS tunnel's keep-alive: echoed, not forwarded
    browser.inbox.put(guac_encode("key", "65", "1"))
    assert _wait(lambda: ["sync", "42"] in browser.instructions())
    assert ["", "ping", "1234"] in browser.instructions()
    assert not any(i[0] == "" for i in guacd.got)
    assert ["key", "65", "1"] in guacd.got
    assert store.get(sid).state == "connected"
    browser.close()
    t.join(timeout=2)
    assert store.get(sid).state == "ended"
    guacd.close()


def test_tunnel_requires_approved_web_session(store):
    approving = store.create("pc-1", "web", True, None)["session"]["id"]
    assert rdp_guac.admit(approving, store)[0] is None
    ios = store.create("pc-1", "ios", True, "K")["session"]["id"]
    store.on_credential("pc-1", {"session_id": ios, "ok": True,
                                 "credential": {"ciphertext": "a", "ephemeral_pub": "b", "nonce": "c"}})
    assert rdp_guac.admit(ios, store)[0] is None
    assert rdp_guac.admit("nope-nope-nope", store)[0] is None
    sid = _approved_web(store)
    assert rdp_guac.admit(sid, store)[0] is not None
    assert rdp_guac.admit(sid, store)[0] is None              # one tunnel per session


def test_guac_auth_error_maps_to_password_message(store, tmp_path):
    guacd = FakeGuacd(after_ready=[guac_encode("error", "Authentication failure (invalid credentials?)", "769")])
    sid = _approved_web(store)
    browser, t = _run(store, sid, guacd, tmp_path)
    assert _wait(lambda: any(i[0] == "error" for i in browser.instructions()))
    err = [i for i in browser.instructions() if i[0] == "error"][0]
    assert err[1] == rdp_guac.PASSWORD_REFUSED
    assert rdp_guac.PASSWORD_REFUSED == ("Windows refused the saved password — update it in Jarvis on the PC "
                                         "(Settings → PC power)")
    assert rdp_guac.map_error(["error", "Logon failure", "519"])[1] == rdp_guac.PASSWORD_REFUSED
    assert rdp_guac.map_error(["error", "x", "519"])[1] == rdp_guac.PASSWORD_REFUSED   # 0x0207
    assert rdp_guac.map_error(["error", "Server busy", "513"]) == ["error", "Server busy", "513"]
    browser.close()
    t.join(timeout=2)
    guacd.close()


def test_drive_folder_removed_on_end(store, tmp_path):
    guacd = FakeGuacd()
    sid = _approved_web(store)
    browser, t = _run(store, sid, guacd, tmp_path)
    folder = tmp_path / "drive" / sid
    assert _wait(lambda: folder.is_dir())
    (folder / "report.txt").write_text("from the PC")
    store.end(sid, "disconnected")
    t.join(timeout=2)
    assert not t.is_alive()
    assert _wait(lambda: not folder.exists())
    guacd.close()


def test_off_closes_tunnels(store, tmp_path):
    guacd = FakeGuacd()
    sid = _approved_web(store)
    browser, t = _run(store, sid, guacd, tmp_path)
    assert _wait(lambda: browser.sent)
    started = time.monotonic()
    store.on_off()
    t.join(timeout=2)
    assert not t.is_alive() and time.monotonic() - started < 2.0
    assert browser.closed.is_set()
    assert store.get(sid).state == "cancelled"
    guacd.close()


def test_upload_limit_2gb(tmp_path):
    assert rdp_guac.MAX_FILE == 2 * 1024 ** 3
    folder = tmp_path / "drive"
    folder.mkdir()
    (folder / "small.txt").write_text("ok")
    big = folder / "huge.iso"
    with open(big, "wb") as f:               # sparse: costs nothing on disk
        f.truncate(rdp_guac.MAX_FILE + 1)
    sub = folder / "nested"
    sub.mkdir()
    with open(sub / "also.bin", "wb") as f:
        f.truncate(rdp_guac.MAX_FILE + 10)
    assert sorted(rdp_guac.check_drive(folder)) == ["huge.iso", os.path.join("nested", "also.bin")]
    assert not big.exists() and (folder / "small.txt").exists()


def test_path_parsing_and_size_query():
    assert rdp_guac.session_id_of("/api/rdp/guac/AbC_-123456789") == "AbC_-123456789"
    assert rdp_guac.session_id_of("/api/rdp/guac/../x") is None
    assert rdp_guac.size_from_query("w=1600&h=900&dpi=144") == (1600, 900, 144)
    assert rdp_guac.size_from_query("w=99999&h=-3&dpi=abc") == (4096, 480, 96)    # clamped, defaults
