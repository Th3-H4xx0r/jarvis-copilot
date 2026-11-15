"""Windows' local links (loopback + token endpoint files) carry the hooks, the app link and
`jc-client agents` exactly like the Unix sockets do. Runs on any OS by forcing tcp mode."""
import json
import os
import shutil
import sys
import tempfile
import threading
import types

import pytest

from jc_client import hook_install, service, unix_server
from jc_client.hook_relay import jc_hook


@pytest.fixture
def d():
    path = tempfile.mkdtemp(dir="/tmp" if sys.platform != "win32" else None, prefix="jwl")
    yield path
    shutil.rmtree(path, ignore_errors=True)


class Capture(unix_server.UnixSocketServer):
    """Reads one line; answers with ``reply`` when given."""

    def __init__(self, path, reply=None):
        super().__init__(path, mode="tcp")
        self.lines = []
        self.reply = reply
        self.got = threading.Event()

    def _connection(self, conn):
        buf = b""
        conn.settimeout(3)
        try:
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
            self.lines.append(json.loads(buf.split(b"\n", 1)[0]))
            self.got.set()
            if self.reply is not None:
                conn.sendall(json.dumps(self.reply).encode() + b"\n")
        finally:
            conn.close()


def test_jc_hook_sends_over_tcp_endpoint(d):
    srv = Capture(os.path.join(d, "hook.sock"))
    srv.start()
    try:
        assert jc_hook._send(srv.path, {"jc": 1, "kind": "event", "agent": "claude", "payload": {"a": 1}}, 0) is None
        assert srv.got.wait(3)
        assert srv.lines[0]["payload"] == {"a": 1}
    finally:
        srv.close()


def test_jc_hook_permission_reply_over_tcp(d):
    srv = Capture(os.path.join(d, "hook.sock"), reply={"decision": "allow"})
    srv.start()
    try:
        reply = jc_hook._send(srv.path, {"jc": 1, "kind": "permission", "agent": "claude", "payload": {}}, 2)
        assert reply == {"decision": "allow"}
    finally:
        srv.close()


def test_jc_hook_no_endpoint_is_silent(d):
    assert jc_hook._send(os.path.join(d, "missing.sock"), {"jc": 1, "kind": "event", "payload": {}}, 1) is None


def test_jc_hook_default_socket_uses_userprofile_on_windows(monkeypatch):
    monkeypatch.setattr(jc_hook.sys, "platform", "win32")
    path = jc_hook._default_socket({"USERPROFILE": r"C:\Users\Pranav K", "HOME": "/c/Users/Pranav K"})
    assert path.startswith(r"C:\Users\Pranav K")
    assert path.endswith("hook.sock")


def test_hook_command_quotes_spaced_paths_win():
    cmd = hook_install.command_base(r"C:\Users\Pranav K\py.exe", r"C:\x y\jc_hook.py")
    assert cmd.startswith('"C:\\Users\\Pranav K\\py.exe" -I "C:\\x y\\jc_hook.py"')


def test_start_agent_hooks_runs_with_tcp_links(monkeypatch, d, capsys):
    monkeypatch.setattr(unix_server, "default_mode", lambda: "tcp")
    monkeypatch.setattr(service, "_hook_socket_path", lambda: os.path.join(d, "hook.sock"))
    monkeypatch.setattr(service, "_ui_socket_path", lambda: os.path.join(d, "ui.sock"))
    from jc_client import plan_usage
    monkeypatch.setattr(plan_usage.CodexPoller, "start", lambda self: None)
    monkeypatch.setattr(plan_usage.ClaudeUsagePoller, "start", lambda self: None)
    svc = service.Service()
    svc.start_agent_hooks()
    try:
        assert svc._hook_server is not None and svc._ui is not None
        for name in ("hook.sock", "ui.sock"):
            with open(os.path.join(d, name), encoding="utf-8") as fh:
                assert set(json.load(fh)) == {"v", "port", "token", "pid"}
        from jc_client import cli
        assert cli.cmd_agents(types.SimpleNamespace(json=True)) == 0
        out = json.loads(capsys.readouterr().out)
        assert out == {"sessions": [], "pending": []}
    finally:
        svc.stop_agent_hooks()
