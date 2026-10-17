"""jc-client's VS Code bridge: route terminal requests to the right window."""
import json
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import threading
import time

import pytest

from jc_client import vscode_bridge
from jc_client.vscode_bridge import VSCodeBridge, shell_pid_of


@pytest.fixture
def sockdir():
    d = tempfile.mkdtemp(dir="/tmp", prefix="jvb")
    yield d
    shutil.rmtree(d, ignore_errors=True)


@pytest.fixture
def bridge(sockdir):
    b = VSCodeBridge(os.path.join(sockdir, "vscode.sock"))
    b.start()
    yield b
    b.stop()


def until(cond, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return cond()


class FakeExtension:
    """Stands in for one VS Code window's extension on the bridge socket."""

    def __init__(self, path, window, folders, pids, ok=True, answer=True):
        self.window = window
        self.folders = folders
        self.pids = pids
        self.ok = ok
        self.answer = answer
        self.received = []
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        threading.Thread(target=self._read, daemon=True).start()

    def hello(self, submit=None):
        msg = {"type": "hello", "window": self.window, "folders": self.folders,
               "terminals": [{"id": i, "pid": p} for i, p in enumerate(self.pids)]}
        if submit is not None:
            msg["submit"] = submit
        self._send(msg)
        return self

    def _send(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())

    def _read(self):
        buf = b""
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    msg = json.loads(line)
                    self.received.append(msg)
                    if self.answer:
                        reply = {"type": "result", "req": msg["req"], "ok": self.ok}
                        if not self.ok:
                            reply["error"] = "nope"
                        self._send(reply)
        except OSError:
            return

    def close(self):
        try:
            self.s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.s.close()


def test_socket_is_private(bridge):
    mode = stat.S_IMODE(os.stat(bridge.path).st_mode)
    assert mode == 0o600


def test_start_replaces_a_stale_socket_file(sockdir):
    path = os.path.join(sockdir, "vscode.sock")
    with open(path, "w") as f:
        f.write("stale")
    b = VSCodeBridge(path)
    b.start()
    try:
        ext = FakeExtension(path, "w1", ["/a"], [11]).hello()
        assert until(lambda: len(b.windows()) == 1)
        ext.close()
    finally:
        b.stop()


def test_windows_reports_latest_hello(bridge):
    ext = FakeExtension(bridge.path, "w1", ["/proj"], [11]).hello()
    assert until(lambda: len(bridge.windows()) == 1)
    ext.pids = [11, 12]
    ext.hello()
    assert until(lambda: [t["pid"] for t in bridge.windows()[0]["terminals"]] == [11, 12])
    w = bridge.windows()[0]
    assert w["window"] == "w1" and w["folders"] == ["/proj"]
    ext.close()


def test_bridge_routes_send_to_window_owning_pid(bridge):
    one = FakeExtension(bridge.path, "w1", ["/a"], [101, 102]).hello()
    two = FakeExtension(bridge.path, "w2", ["/b"], [201]).hello()
    assert until(lambda: len(bridge.windows()) == 2)

    assert bridge.send_text(201, "fix the tests") is True
    assert [m["type"] for m in two.received] == ["send_text"]
    assert two.received[0]["pid"] == 201
    assert two.received[0]["text"] == "fix the tests"
    assert "req" in two.received[0]
    assert one.received == []

    assert bridge.focus(102) is True
    assert [m["type"] for m in one.received] == ["focus"]
    assert one.received[0]["pid"] == 102
    one.close()
    two.close()


def test_no_window_returns_false(bridge):
    t0 = time.time()
    assert bridge.send_text(999, "hi") is False
    assert bridge.focus(999) is False
    assert bridge.run_in_terminal("/nowhere", "ls") is False
    assert time.time() - t0 < 1.0  # no window → answered at once, not on timeout

    ext = FakeExtension(bridge.path, "w1", ["/a"], [11]).hello()
    assert until(lambda: len(bridge.windows()) == 1)
    assert bridge.send_text(999, "hi") is False
    assert bridge.run_in_terminal("/elsewhere", "ls") is False
    assert ext.received == []
    ext.close()


def test_window_saying_no_or_silent_returns_false(bridge):
    refuses = FakeExtension(bridge.path, "w1", ["/a"], [11], ok=False).hello()
    silent = FakeExtension(bridge.path, "w2", ["/b"], [22], answer=False).hello()
    assert until(lambda: len(bridge.windows()) == 2)
    assert bridge.send_text(11, "hi") is False
    t0 = time.time()
    assert bridge.send_text(22, "hi", timeout=0.3) is False
    assert time.time() - t0 < 2.0
    refuses.close()
    silent.close()


def test_run_picks_window_by_folder(bridge):
    outer = FakeExtension(bridge.path, "w1", ["/Users/x/proj"], [11]).hello()
    inner = FakeExtension(bridge.path, "w2", ["/Users/x/proj/sub"], [22]).hello()
    assert until(lambda: len(bridge.windows()) == 2)

    assert bridge.run_in_terminal("/Users/x/proj/sub/pkg", "claude --resume abc") is True
    assert [m["type"] for m in inner.received] == ["run"]
    assert inner.received[0]["cwd"] == "/Users/x/proj/sub/pkg"
    assert inner.received[0]["command"] == "claude --resume abc"
    assert outer.received == []

    assert bridge.run_in_terminal("/Users/x/proj/other", "codex resume") is True
    assert [m["type"] for m in outer.received] == ["run"]
    assert len(inner.received) == 1

    # A sibling folder sharing a prefix is not inside it.
    assert bridge.run_in_terminal("/Users/x/project2", "ls") is False
    outer.close()
    inner.close()


def test_dead_connection_dropped(bridge):
    ext = FakeExtension(bridge.path, "w1", ["/a"], [11]).hello()
    assert until(lambda: len(bridge.windows()) == 1)
    ext.close()
    assert until(lambda: bridge.windows() == [])
    assert bridge.send_text(11, "hi") is False


def test_pending_request_fails_fast_when_window_closes(bridge):
    ext = FakeExtension(bridge.path, "w1", ["/a"], [11], answer=False).hello()
    assert until(lambda: len(bridge.windows()) == 1)
    threading.Timer(0.2, ext.close).start()
    t0 = time.time()
    assert bridge.send_text(11, "hi", timeout=5.0) is False
    assert time.time() - t0 < 2.0


def test_shell_pid_of_parses_ps(monkeypatch):
    calls = []

    def fake_run(argv, **kw):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=" 4242\n", stderr="")

    monkeypatch.setattr(vscode_bridge.subprocess, "run", fake_run)
    assert shell_pid_of(1234) == 4242
    assert calls == [["ps", "-o", "ppid=", "-p", "1234"]]

    monkeypatch.setattr(vscode_bridge.subprocess, "run",
                        lambda argv, **kw: subprocess.CompletedProcess(argv, 1, stdout="", stderr=""))
    assert shell_pid_of(1234) is None

    def boom(argv, **kw):
        raise OSError("no ps")

    monkeypatch.setattr(vscode_bridge.subprocess, "run", boom)
    assert shell_pid_of(1234) is None


def test_shell_pid_of_real_process():
    assert shell_pid_of(os.getpid()) == os.getppid()


def test_terminal_pid_for_walks_up_to_a_known_shell(bridge, monkeypatch):
    # codex (rust) ← node wrapper ← zsh (the VS Code terminal's shell)
    parents = {300: 200, 200: 100, 100: 1}
    monkeypatch.setattr(vscode_bridge, "shell_pid_of", lambda pid: parents.get(pid))
    ext = FakeExtension(bridge.path, "w1", ["/a"], [100]).hello()
    assert until(lambda: len(bridge.windows()) == 1)
    assert bridge.terminal_pid_for(300) == 100
    assert bridge.terminal_pid_for(100) == 100
    assert bridge.terminal_pid_for(999) is None
    ext.close()


def test_send_now_asks_the_terminal_for_ctrl_enter(monkeypatch):
    from jc_client.vscode_bridge import VSCodeBridge
    b = VSCodeBridge(sock_path="/tmp/jc-unused-test.sock")
    seen = {}
    conn = type("Conn", (), {"hello": {"submit": ["enter", "now"]}})()
    monkeypatch.setattr(b, "_owner", lambda pid: conn)
    monkeypatch.setattr(b, "_request", lambda conn, msg, timeout: seen.update(msg) or True)
    assert b.send_text(5, "hi", now=True) and seen["submit"] == "now"
    assert b.send_text(5, "hi") and seen["submit"] == "enter"


def test_send_now_reaches_a_window_still_on_the_old_extension(bridge):
    """Extension 0.1.0 ignores "submit": it pastes the text and presses Enter.
    Closing the paste early and pressing Ctrl+Enter inside it sends it now (the
    Enter after it lands on an empty prompt and does nothing)."""
    old = FakeExtension(bridge.path, "w1", ["/a"], [101]).hello()
    new = FakeExtension(bridge.path, "w2", ["/b"], [201]).hello(submit=["enter", "now"])
    assert until(lambda: len(bridge.windows()) == 2)
    assert bridge.send_text(101, "go", now=True) is True
    assert old.received[-1]["text"] == "go\x1b[201~\x1b[13;5u\x1b[200~"
    assert bridge.send_text(101, "go") is True and old.received[-1]["text"] == "go"
    assert bridge.send_text(201, "go", now=True) is True
    assert new.received[-1]["submit"] == "now" and new.received[-1]["text"] == "go"
    old.close()
    new.close()
