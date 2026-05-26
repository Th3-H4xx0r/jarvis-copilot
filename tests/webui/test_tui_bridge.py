"""Tests for the /api/tui/ws → tui_gateway.entry bridge."""
from __future__ import annotations

import importlib
import io
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))


def _bridge():
    from api import tui_bridge
    importlib.reload(tui_bridge)
    return tui_bridge


def test_claims_only_its_path():
    tb = _bridge()

    class H:
        path = "/api/voice/s2s/ws"

    # Wrong path → returns False (doesn't claim), without needing a socket.
    assert tb.handle_websocket(H(), urlparse("/api/voice/s2s/ws")) is False


def test_write_to_gateway_appends_newline():
    tb = _bridge()

    class FakeProc:
        def __init__(self):
            self.stdin = io.BytesIO()
        def flush(self):
            pass

    proc = FakeProc()
    proc.stdin.flush = lambda: None
    assert tb._write_to_gateway(proc, '{"method":"ping"}') is True
    assert proc.stdin.getvalue() == b'{"method":"ping"}\n'


def test_pump_stdout_forwards_lines():
    tb = _bridge()

    class FakeProc:
        stdout = io.BytesIO(b'{"jsonrpc":"2.0","id":1,"result":{}}\n{"event":"ready"}\n')

    sent = []
    tb._pump_stdout(FakeProc(), lambda line: (sent.append(line) or True), stop=lambda: False)
    assert sent[0].startswith('{"jsonrpc"')
    assert sent[1] == '{"event":"ready"}'
