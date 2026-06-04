"""Tests for the desktop MCP relay manager (Phase 2, 2c)."""

import json
import os
import sys
import threading

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "desktop_client"))

from jc_client.mcp_relay import (  # noqa: E402
    McpRelayManager, build_playwright_command,
)


class _FakeStdin:
    def __init__(self):
        self.written = []

    def write(self, s):
        self.written.append(s)

    def flush(self):
        pass


class _FakeStdout:
    """Yields the given lines, then optionally parks on `block` (so the reader
    thread doesn't immediately emit mcp_closed during a handle_open test)."""

    def __init__(self, lines, block=None):
        self._it = iter(lines)
        self._block = block

    def __iter__(self):
        return self

    def __next__(self):
        try:
            return next(self._it)
        except StopIteration:
            if self._block is not None:
                self._block.wait()
            raise


class _FakeProc:
    def __init__(self, lines=(), block=None):
        self.stdout = _FakeStdout(list(lines), block)
        self.stdin = _FakeStdin()
        self.terminated = False
        self._block = block

    def terminate(self):
        self.terminated = True
        if self._block is not None:
            self._block.set()  # release the parked reader thread


def _mgr(spawn, sends):
    return McpRelayManager(
        send=sends.append,
        profile_dir="/tmp/test-profile",
        spawn=spawn,
    )


def _types(sends):
    return [json.loads(s)["type"] for s in sends]


# ── command building ────────────────────────────────────────────────────────

def test_build_command_honors_browser_enum():
    cmd = build_playwright_command({"browser": "msedge"}, "/p")
    assert cmd[:2] == ["npx", "@playwright/mcp@latest"]
    assert "--browser" in cmd and "msedge" in cmd
    assert cmd[cmd.index("--user-data-dir") + 1] == "/p"


def test_build_command_rejects_bad_browser_and_ignores_server_path():
    # Unknown browser → default chrome; server-supplied user-data-dir is ignored.
    cmd = build_playwright_command(
        {"browser": "evil", "user-data-dir": "/etc/shadow"}, "/safe-profile"
    )
    assert "chrome" in cmd
    assert "/etc/shadow" not in cmd
    assert "/safe-profile" in cmd


# ── lifecycle ───────────────────────────────────────────────────────────────

def test_handle_open_spawn_failure_emits_error():
    sends = []

    def boom(_cmd):
        raise OSError("npx not found")

    mgr = _mgr(boom, sends)
    mgr.handle_open("s1", {"browser": "chrome"})
    assert _types(sends) == ["mcp_error"]
    assert "spawn failed" in json.loads(sends[0])["error"]


def test_handle_open_emits_ready_and_registers():
    sends = []
    block = threading.Event()
    proc = _FakeProc(lines=(), block=block)
    mgr = _mgr(lambda _cmd: proc, sends)
    try:
        mgr.handle_open("s2", {"browser": "chrome"})
        assert "mcp_ready" in _types(sends)
        assert "s2" in mgr._procs
    finally:
        mgr.handle_close("s2")  # releases the parked reader + terminates
    assert proc.terminated is True
    assert "s2" not in mgr._procs


def test_pump_stdout_forwards_frames_then_closed():
    sends = []
    proc = _FakeProc(lines=['{"jsonrpc":"2.0","id":1}', "", '{"id":2}'])
    mgr = _mgr(lambda _cmd: proc, sends)
    mgr._procs["s3"] = proc  # pre-register as handle_open would
    mgr._pump_stdout("s3", proc)  # run synchronously
    types = _types(sends)
    # two non-empty lines → two mcp_frame, then mcp_closed when stdout ends
    assert types == ["mcp_frame", "mcp_frame", "mcp_closed"]
    datas = [json.loads(s).get("data") for s in sends if json.loads(s)["type"] == "mcp_frame"]
    assert datas == ['{"jsonrpc":"2.0","id":1}', '{"id":2}']
    assert "s3" not in mgr._procs


def test_handle_frame_writes_line_to_stdin():
    sends = []
    proc = _FakeProc()
    mgr = _mgr(lambda _cmd: proc, sends)
    mgr._procs["s4"] = proc
    mgr.handle_frame("s4", '{"method":"tools/list"}')
    assert proc.stdin.written == ['{"method":"tools/list"}\n']


def test_handle_frame_unknown_session_is_noop():
    sends = []
    mgr = _mgr(lambda _cmd: _FakeProc(), sends)
    mgr.handle_frame("ghost", "{}")  # must not raise
    assert sends == []


def test_shutdown_all_terminates_children():
    sends = []
    p1, p2 = _FakeProc(), _FakeProc()
    procs = iter([p1, p2])
    mgr = _mgr(lambda _cmd: next(procs), sends)
    mgr._procs["a"] = p1
    mgr._procs["b"] = p2
    mgr.shutdown_all()
    assert p1.terminated and p2.terminated
    assert mgr._procs == {}
