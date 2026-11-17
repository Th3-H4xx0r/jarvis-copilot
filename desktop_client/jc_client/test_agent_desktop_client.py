"""The long-lived agent-desktop child: MCP over stdio, one call at a time, restarted when it hangs or dies."""
from __future__ import annotations

import json
import sys
import textwrap
import time

from jc_client import agent_desktop_client as adc

# A stand-in for `agent-desktop mcp`: answers initialize and tools/call; its mode comes from argv.
FAKE = textwrap.dedent('''
    import json, os, sys, time
    mode, log = sys.argv[1], sys.argv[2]
    calls = 0
    for line in sys.stdin:
        msg = json.loads(line)
        with open(log, "a") as fh:
            fh.write(msg.get("method", "") + "\\n")
        if "id" not in msg:
            continue
        if msg["method"] == "initialize":
            out = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "fake"}}
        else:
            calls += 1
            if mode == "hang_first" and calls == 1 and not os.path.exists(log + ".hung"):
                open(log + ".hung", "w").close()
                time.sleep(30)
            env = {k: v for k, v in os.environ.items() if k.startswith("AGENT_DESKTOP")}
            envelope = {"ok": True, "data": {"tool": msg["params"]["name"], "pid": os.getpid(), "env": env}}
            out = {"content": [{"type": "text", "text": json.dumps(envelope)}]}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": out}) + "\\n")
        sys.stdout.flush()
        if mode == "exit_after_one" and calls == 1:
            sys.exit(0)
''')


def _client(tmp_path, mode="ok"):
    script = tmp_path / "fake_mcp.py"
    script.write_text(FAKE)
    log = tmp_path / "calls.log"
    return adc.AgentDesktop([sys.executable, str(script), mode, str(log)], str(tmp_path / "home")), log


def test_initializes_once_and_calls_tools(tmp_path):
    client, log = _client(tmp_path)
    try:
        a = client.call("desktop_snapshot", {"app": "Finder"})
        b = client.call("desktop_click", {"ref_id": "@s1:e1"})
    finally:
        client.close()
    assert a["ok"] and a["data"]["tool"] == "desktop_snapshot"
    assert b["data"]["tool"] == "desktop_click"
    lines = log.read_text().split()
    assert lines.count("initialize") == 1 and lines.count("tools/call") == 2


def test_hung_child_times_out_and_restarts(tmp_path):
    client, _ = _client(tmp_path, "hang_first")
    try:
        t = time.monotonic()
        first = client.call("desktop_snapshot", {}, timeout=1.0)
        assert time.monotonic() - t < 2.5
        assert first == {"ok": False, "error": {"code": "CLIENT_TIMEOUT", "message": "agent-desktop didn't answer"}}
        second = client.call("desktop_snapshot", {}, timeout=5.0)
    finally:
        client.close()
    assert second["ok"]


def test_dead_child_restarts(tmp_path):
    client, _ = _client(tmp_path, "exit_after_one")
    try:
        first = client.call("desktop_snapshot", {})
        time.sleep(0.3)
        second = client.call("desktop_snapshot", {})
    finally:
        client.close()
    assert first["ok"] and second["ok"]
    assert first["data"]["pid"] != second["data"]["pid"]


def test_env_sets_home_and_no_trace(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENT_DESKTOP_SESSION", "leaked")
    client, _ = _client(tmp_path)
    try:
        env = client.call("desktop_snapshot", {})["data"]["env"]
    finally:
        client.close()
    assert env == {"AGENT_DESKTOP_HOME": str(tmp_path / "home")}


def test_home_is_private(tmp_path):
    # agent-desktop refuses a state root others can read ("private file parent is accessible…").
    if sys.platform == "win32":
        return
    import os
    import stat
    (tmp_path / "home").mkdir(mode=0o755)
    client, _ = _client(tmp_path)
    try:
        client.call("desktop_snapshot", {})
    finally:
        client.close()
    assert stat.S_IMODE(os.stat(tmp_path / "home").st_mode) == 0o700


def test_get_none_when_not_installed(tmp_path, monkeypatch):
    monkeypatch.setattr(adc, "_client", None)
    monkeypatch.setattr(adc, "state_dir", lambda: tmp_path)
    assert adc.get() is None


def test_get_reuses_one_client(tmp_path, monkeypatch):
    (tmp_path / "bin" / "agent-desktop-1.3.1").mkdir(parents=True)
    binary = tmp_path / "bin" / "agent-desktop-1.3.1" / ("agent-desktop.exe" if sys.platform == "win32" else "agent-desktop")
    binary.write_text("")
    monkeypatch.setattr(adc, "_client", None)
    monkeypatch.setattr(adc, "state_dir", lambda: tmp_path)
    first = adc.get()
    assert first is not None and adc.get() is first
    assert first.argv == [str(binary), "mcp"]
    assert json.dumps(first.home).endswith('agent-desktop-home"')
