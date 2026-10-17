"""This Mac's roster of live agent sessions, sent to the server."""
import json
import subprocess

from jc_client.agent_roster import RosterAgent

AGENTS = json.dumps([
    {"pid": 4707, "cwd": "/Users/p/app", "kind": "interactive", "sessionId": "s1",
     "name": "Fix it", "status": "busy"},
    {"id": "bg1", "cwd": "/Users/p/app", "kind": "background", "sessionId": "s2",
     "name": "bg", "status": "idle", "state": "done"},
])


def _run(stdout):
    def run(argv, **kw):
        out = kw.get("stdout")
        if hasattr(out, "write"):
            out.write(stdout)
            out.flush()
        return subprocess.CompletedProcess(argv, 0, None, None)
    return run


def test_scan_sends_claude_entries_with_hook_terminal():
    sent = []
    r = RosterAgent(sent.append, run=_run(AGENTS), alive=lambda pid: True)
    r.note_hook("claude", "s1", pid=4707, cwd="/Users/p/app",
                terminal={"term_program": "vscode"})
    entries = r.scan_now()
    assert sent[-1]["name"] == "agent_roster" and sent[-1]["type"] == "event"
    s1 = next(e for e in entries if e["session_id"] == "s1")
    assert s1["pid"] == 4707 and s1["kind"] == "interactive"
    assert s1["terminal"] == {"term_program": "vscode"}
    s2 = next(e for e in entries if e["session_id"] == "s2")
    assert s2["bg_id"] == "bg1" and s2["kind"] == "background"
    assert sent[-1]["data"]["agents"] == ["claude", "codex"]


def test_codex_sessions_come_from_hooks_and_die_with_their_pid():
    alive = {"pid": True}
    r = RosterAgent(lambda f: None, run=_run("[]"), alive=lambda pid: alive["pid"])
    r.note_hook("codex", "c1", pid=99, cwd="/Users/p/app", terminal={})
    assert [e["session_id"] for e in r.scan_now()] == ["c1"]
    alive["pid"] = False
    assert r.scan_now() == []


def test_garbage_output_sends_codex_only():
    r = RosterAgent(lambda f: None, run=_run("not json"), alive=lambda pid: True)
    assert r.scan_now() == []


def test_trigger_debounces(monkeypatch):
    calls = []
    r = RosterAgent(lambda f: None, run=_run("[]"), alive=lambda pid: True, debounce=0.05)
    monkeypatch.setattr(r, "scan_now", lambda: calls.append(1) or [])
    for _ in range(5):
        r.trigger("hook")
    import time
    time.sleep(0.2)
    assert calls == [1]
    r.close()


def test_heartbeat_only_while_live():
    r = RosterAgent(lambda f: None, run=_run("[]"), alive=lambda pid: True)
    r.scan_now()
    assert r.next_heartbeat() is None
    r2 = RosterAgent(lambda f: None, run=_run(AGENTS), alive=lambda pid: True, heartbeat=60.0)
    r2.scan_now()
    assert r2.next_heartbeat() == 60.0


def test_titles_are_one_short_line():
    long = json.dumps([{"pid": 1, "cwd": "/w", "kind": "interactive", "sessionId": "s1",
                        "name": "Summarise this\n" + "x" * 5000, "status": "idle"}])
    r = RosterAgent(lambda f: None, run=_run(long), alive=lambda pid: True)
    (e,) = r.scan_now()
    assert e["name"] == "Summarise this"
    long2 = json.dumps([{"pid": 1, "cwd": "/w", "kind": "interactive", "sessionId": "s2",
                         "name": "y" * 500, "status": "idle"}])
    (e2,) = RosterAgent(lambda f: None, run=_run(long2), alive=lambda pid: True).scan_now()
    assert len(e2["name"]) == 120 and e2["name"].endswith("…")


def test_a_failed_claude_listing_does_not_report_claude_sessions_gone():
    """`claude agents --json` failing (missing binary, crash, timeout) must not
    send an empty Claude list: the server would end every live Claude session."""
    def boom(argv, **kw):
        raise FileNotFoundError(argv[0])

    sent = []
    r = RosterAgent(sent.append, run=boom, alive=lambda pid: True)
    r.note_hook("codex", "c1", pid=77, cwd="/w")
    r.scan_now()
    data = sent[-1]["data"]
    assert "claude" not in data["agents"] and "codex" in data["agents"]
    assert [e["session_id"] for e in data["entries"]] == ["c1"]


def test_claude_is_found_outside_the_launchd_path(tmp_path, monkeypatch):
    """jc-client runs under launchd (PATH=/usr/bin:/bin:...); Claude Code's
    installer puts `claude` in ~/.local/bin."""
    from jc_client.agent_roster import find_claude
    bin_dir = tmp_path / ".local" / "bin"
    bin_dir.mkdir(parents=True)
    exe = bin_dir / "claude"
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    assert find_claude(home=str(tmp_path), path_env="/usr/bin:/bin") == str(exe)
