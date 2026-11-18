"""The JarvisUnlock pipe client (W4): one request line, one reply line, a clear error when the helper is
missing, a retry while the pipe is busy."""
from __future__ import annotations

import json

from jc_client import helper_pipe


class Pipe:
    def __init__(self, reply: bytes):
        self.written, self.reply, self.closed = b"", reply, False

    def write(self, data):
        self.written += data
        return len(data)

    def read(self, n=-1):
        out, self.reply = self.reply, b""
        return out

    def close(self):
        self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def test_helper_pipe_round_trip():
    pipe = Pipe(b'{"ok":true,"exit_code":0,"output":"done","truncated":false,"timed_out":false,"duration_ms":9}\n')
    opened = []
    out = helper_pipe.admin_run("wsl --install", "n" * 32, 1700000000, "c2ln", 600,
                                opener=lambda path: opened.append(path) or pipe)
    assert opened == [helper_pipe.PIPE_PATH] == [r"\\.\pipe\JarvisUnlock"]
    assert pipe.written.decode() == json.dumps({"admin_run": {"command": "wsl --install", "nonce": "n" * 32,
                                                              "ts": 1700000000, "signature": "c2ln",
                                                              "timeout_s": 600}}) + "\n"
    assert out == {"ok": True, "exit_code": 0, "output": "done", "truncated": False, "timed_out": False,
                   "duration_ms": 9} and pipe.closed


def test_helper_pipe_missing_helper_says_so():
    def missing(path):
        raise FileNotFoundError(2, "No such file")
    assert helper_pipe.admin_run("x", "n", 1, "s", 60, opener=missing) == {
        "ok": False, "error": "The Jarvis helper isn't running on this PC. Reinstall it in Jarvis Settings → PC power."}


def test_helper_pipe_retries_a_busy_pipe():
    tries = []
    pipe = Pipe(b'{"ok":false,"error":"bad signature"}\n')

    def busy_then_open(path):
        tries.append(1)
        if len(tries) < 3:
            raise OSError(231, "All pipe instances are busy")
        return pipe
    out = helper_pipe.admin_run("x", "n", 1, "s", 60, opener=busy_then_open, connect_wait_s=5.0)
    assert len(tries) == 3 and out == {"ok": False, "error": "bad signature"}


def test_helper_pipe_bad_reply_is_an_error():
    out = helper_pipe.admin_run("x", "n", 1, "s", 60, opener=lambda p: Pipe(b"garbage\n"))
    assert out["ok"] is False and "helper" in out["error"].lower()


def test_a_stopped_helper_is_started_and_tried_again():
    # Live 2026-11-18: the helper service had been stopped; jc-client starts it (the installer lets him).
    pipe = Pipe(b'{"ok":true,"exit_code":0,"output":"","truncated":false,"timed_out":false,"duration_ms":1}\n')
    opened, started = [], []

    def opener(path):
        opened.append(1)
        if not started:
            raise FileNotFoundError(2, "No such file")
        return pipe
    out = helper_pipe.admin_run("x", "n", 1, "s", 60, opener=opener, start_helper=lambda: started.append(1) or True,
                                connect_wait_s=2.0)
    assert started == [1] and out["ok"] is True
