"""jc-hook: the relay Claude Code (and other agents) run for every hook event.

Contract: never block the agent. Fire-and-forget events give up after 0.3 s;
blocking kinds (PermissionRequest, the AskUserQuestion `--ask` hook) print a
decision only when Jarvis answered one; everything exits 0.
"""
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time

import pytest

from jc_client.hook_relay import jc_hook


class FakeJarvis:
    """A one-shot UNIX socket server standing in for jc-client's hook server."""

    def __init__(self, reply=None, delay=0.0):
        self.dir = tempfile.mkdtemp(dir="/tmp", prefix="jch")
        self.path = os.path.join(self.dir, "h.sock")
        self.reply = reply
        self.delay = delay
        self.frames = []
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self.path)
        self._srv.listen(4)
        self._t = threading.Thread(target=self._serve, daemon=True)
        self._t.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
            if buf.strip():
                self.frames.append(json.loads(buf.split(b"\n", 1)[0]))
            if self.reply is not None:
                time.sleep(self.delay)
                try:
                    conn.sendall((json.dumps(self.reply) + "\n").encode())
                except OSError:
                    pass
            conn.close()

    def close(self):
        self._srv.close()
        shutil.rmtree(self.dir, ignore_errors=True)


@pytest.fixture
def jarvis():
    made = []

    def make(**kw):
        j = FakeJarvis(**kw)
        made.append(j)
        return j

    yield make
    for j in made:
        j.close()


def run(argv, payload, env=None):
    raw = json.dumps(payload).encode() if payload is not None else b""
    return jc_hook.main(argv, raw, env or {})


def wait_frames(j, n=1, timeout=2.0):
    end = time.time() + timeout
    while len(j.frames) < n and time.time() < end:
        time.sleep(0.01)
    return j.frames


def test_event_is_forwarded_as_one_frame(jarvis):
    j = jarvis()
    out, code = run(["--socket", j.path],
                    {"hook_event_name": "UserPromptSubmit", "session_id": "s1",
                     "cwd": "/w/app", "prompt": "fix it"},
                    env={"TERM_PROGRAM": "Apple_Terminal",
                         "__CFBundleIdentifier": "com.apple.Terminal"})
    assert (out, code) == ("", 0)
    frame = wait_frames(j)[0]
    assert frame["jc"] == 1 and frame["kind"] == "event"
    assert frame["agent"] == "claude"
    p = frame["payload"]
    assert p["hook_event_name"] == "UserPromptSubmit"
    assert p["session_id"] == "s1"
    assert p["term_program"] == "Apple_Terminal"
    assert p["bundle_id"] == "com.apple.Terminal"


def test_no_socket_exits_fast():
    start = time.time()
    out, code = run(["--socket", "/tmp/jch-does-not-exist.sock"],
                    {"hook_event_name": "PreToolUse", "tool_name": "Bash"})
    assert (out, code) == ("", 0)
    assert time.time() - start < 0.5


def test_bad_stdin_exits_cleanly():
    assert jc_hook.main(["--socket", "/tmp/x.sock"], b"{not json", {}) == ("", 0)
    assert jc_hook.main(["--socket", "/tmp/x.sock"], b"", {}) == ("", 0)


def test_permission_allow_prints_hook_output(jarvis):
    j = jarvis(reply={"decision": "allow"})
    out, code = run(["--socket", j.path],
                    {"hook_event_name": "PermissionRequest", "session_id": "s",
                     "tool_name": "Bash", "tool_input": {"command": "rm -rf build"}})
    assert code == 0
    assert json.loads(out) == {"hookSpecificOutput": {
        "hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
    assert j.frames[0]["kind"] == "permission"


def test_permission_deny_carries_message(jarvis):
    j = jarvis(reply={"decision": "deny", "message": "use make clean"})
    out, _ = run(["--socket", j.path],
                 {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                  "tool_input": {"command": "rm -rf build"}})
    dec = json.loads(out)["hookSpecificOutput"]["decision"]
    assert dec == {"behavior": "deny", "message": "use make clean"}


def test_permission_always_echoes_suggestions(jarvis):
    sugg = [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm test"}],
             "behavior": "allow", "destination": "localSettings"}]
    j = jarvis(reply={"decision": "always"})
    out, _ = run(["--socket", j.path],
                 {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                  "tool_input": {"command": "npm test"}, "permission_suggestions": sugg})
    dec = json.loads(out)["hookSpecificOutput"]["decision"]
    assert dec == {"behavior": "allow", "updatedPermissions": sugg}


def test_permission_ask_prints_nothing(jarvis):
    j = jarvis(reply={"decision": "ask"})
    out, code = run(["--socket", j.path],
                    {"hook_event_name": "PermissionRequest", "tool_name": "Bash"})
    assert (out, code) == ("", 0)


def test_permission_no_server_prints_nothing():
    out, code = run(["--socket", "/tmp/jch-none.sock"],
                    {"hook_event_name": "PermissionRequest", "tool_name": "Bash"})
    assert (out, code) == ("", 0)


def test_permission_server_closes_without_reply(jarvis):
    j = jarvis()  # reads the frame, closes without answering
    out, code = run(["--socket", j.path],
                    {"hook_event_name": "PermissionRequest", "tool_name": "Bash"})
    assert (out, code) == ("", 0)


def test_ask_answer_returns_updated_input(jarvis):
    questions = [{"question": "Which db?", "header": "DB", "multiSelect": False,
                  "options": [{"label": "Postgres"}, {"label": "SQLite"}]}]
    j = jarvis(reply={"decision": "answer", "answers": {"Which db?": "SQLite"}})
    out, code = run(["--socket", j.path, "--ask"],
                    {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                     "tool_input": {"questions": questions}})
    assert code == 0
    assert json.loads(out) == {"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "allow",
        "updatedInput": {"questions": questions, "answers": {"Which db?": "SQLite"}}}}
    assert j.frames[0]["kind"] == "ask"


def test_ask_ignores_other_tools(jarvis):
    j = jarvis(reply={"decision": "answer", "answers": {}})
    out, code = run(["--socket", j.path, "--ask"],
                    {"hook_event_name": "PreToolUse", "tool_name": "Bash"})
    assert (out, code) == ("", 0)
    time.sleep(0.05)
    assert j.frames == []


def test_ask_unanswered_falls_back_to_terminal(jarvis):
    j = jarvis(reply={"decision": "ask"})
    out, _ = run(["--socket", j.path, "--ask"],
                 {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": []}})
    assert out == ""


def test_statusline_forwards_rate_limits_and_runs_previous(jarvis, tmp_path, monkeypatch):
    j = jarvis()
    prev = tmp_path / "statusline-previous.json"
    prev.write_text(json.dumps({"command": "cat >/dev/null; printf 'old status'"}))
    monkeypatch.setattr(jc_hook, "_previous_statusline_file", lambda: str(prev))
    limits = {"five_hour": {"used_percentage": 42, "resets_at": 1760000000},
              "seven_day": {"used_percentage": 7.5, "resets_at": 1760500000}}
    out, code = run(["--socket", j.path, "--statusline"],
                    {"session_id": "s1", "rate_limits": limits, "model": {"id": "x"}})
    assert (out, code) == ("old status", 0)
    frame = wait_frames(j)[0]
    assert frame["kind"] == "statusline"
    assert frame["payload"]["rate_limits"] == limits
    assert frame["payload"]["session_id"] == "s1"


def test_statusline_without_previous_prints_nothing(jarvis, tmp_path, monkeypatch):
    j = jarvis()
    monkeypatch.setattr(jc_hook, "_previous_statusline_file",
                        lambda: str(tmp_path / "missing.json"))
    out, code = run(["--socket", j.path, "--statusline"], {"rate_limits": {}})
    assert (out, code) == ("", 0)


def test_statusline_that_chains_back_to_us_runs_once(jarvis, tmp_path, monkeypatch):
    # Another status line tool saved ours as *its* previous one, so the command
    # we chain to runs jc-hook --statusline again. Each pass is counted; the cap
    # of 20 only stops a regression from forking forever.
    j = jarvis()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    relay = bin_dir / "jc-hook"
    shutil.copy(jc_hook.__file__, relay)
    prev = bin_dir / "statusline-previous.json"
    runs = tmp_path / "runs"
    runs.touch()
    prev.write_text(json.dumps({"command": (
        f'[ $(wc -l < "{runs}") -ge 20 ] && exit 0; echo run >> "{runs}"; '
        f'printf "other tool\\n"; "{sys.executable}" -I "{relay}" --socket "{j.path}" --statusline')}))
    monkeypatch.setattr(jc_hook, "_previous_statusline_file", lambda: str(prev))
    out, code = run(["--socket", j.path, "--statusline"], {"session_id": "s1", "rate_limits": {}})
    assert (out, code) == ("other tool\n", 0)
    assert runs.read_text().count("run") == 1
    time.sleep(0.1)
    assert [f["kind"] for f in j.frames] == ["statusline"]


def _gone(pid, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.02)
    return False


def test_statusline_timeout_kills_everything_the_previous_command_started(jarvis, tmp_path,
                                                                          monkeypatch):
    j = jarvis()
    prev = tmp_path / "statusline-previous.json"
    pid_file = tmp_path / "pid"
    prev.write_text(json.dumps({"command": f'sleep 30 & echo $! > "{pid_file}"; wait'}))
    monkeypatch.setattr(jc_hook, "_previous_statusline_file", lambda: str(prev))
    monkeypatch.setattr(jc_hook, "STATUSLINE_TIMEOUT", 0.5)
    start = time.time()
    out, code = run(["--socket", j.path, "--statusline"], {"rate_limits": {}})
    assert (out, code) == ("", 0)
    assert time.time() - start < 3
    assert _gone(int(pid_file.read_text()))


def test_trims_large_payload(jarvis):
    j = jarvis()
    big = "x" * (1024 * 1024)
    run(["--socket", j.path],
        {"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "cat big.log"},
         "tool_response": {"stdout": big, "stderr": ""}})
    frame = wait_frames(j)[0]
    assert len(json.dumps(frame)) < jc_hook.MAX_FRAME
    assert frame["payload"]["jc_trimmed"] is True
    assert frame["payload"]["tool_input"]["command"] == "cat big.log"


def test_agent_flag_and_gemini_event_names(jarvis):
    j = jarvis()
    run(["--socket", j.path, "--agent", "gemini"],
        {"hook_event_name": "BeforeTool", "toolCall": {"name": "shell", "args": {"CommandLine": "ls"}},
         "conversationId": "g1"})
    frame = wait_frames(j)[0]
    assert frame["agent"] == "gemini"
    p = frame["payload"]
    assert p["hook_event_name"] == "PreToolUse"
    assert p["tool_name"] == "shell"
    assert p["tool_input"]["command"] == "ls"
    assert p["session_id"] == "g1"


def test_copilot_camel_case_and_fail_closed(jarvis):
    j = jarvis()
    out, _ = run(["--socket", j.path, "--agent", "copilot", "sessionStart"],
                 {"sessionId": "c1", "workdir": "/w"})
    assert out == "{}"
    p = wait_frames(j)[0]["payload"]
    assert p["hook_event_name"] == "SessionStart"
    assert p["session_id"] == "c1" and p["cwd"] == "/w"
    out, _ = run(["--socket", "/tmp/jch-none.sock", "--agent", "copilot", "permissionRequest"],
                 {"toolName": "bash", "toolArgs": {"command": "ls"}})
    assert json.loads(out) == {"permissionDecision": "ask"}


def test_copilot_empty_permission_body_still_fails_closed():
    out, code = jc_hook.main(["--socket", "/tmp/jch-none.sock", "--agent", "copilot",
                              "permissionRequest"], b"{}", {})
    assert (json.loads(out), code) == ({"permissionDecision": "ask"}, 0)


def test_copilot_allow_uses_flat_decision(jarvis):
    j = jarvis(reply={"decision": "allow"})
    out, _ = run(["--socket", j.path, "--agent", "copilot", "permissionRequest"],
                 {"toolName": "bash", "toolArgs": {"command": "ls"}})
    assert json.loads(out) == {"permissionDecision": "allow"}


def test_claude_desktop_entrypoint_tags_agent(jarvis):
    j = jarvis()
    run(["--socket", j.path], {"hook_event_name": "Stop", "session_id": "d"},
        env={"CLAUDE_CODE_ENTRYPOINT": "claude-desktop"})
    assert wait_frames(j)[0]["agent"] == "claude-desktop"


def test_antigravity_pretool_answers_ask(jarvis):
    j = jarvis()
    out, _ = run(["--socket", j.path, "--agent", "antigravity"],
                 {"hook_event_name": "PreToolUse", "toolCall": {"name": "run"}})
    assert json.loads(out) == {"decision": "ask"}


def test_cwd_falls_back_to_process_cwd(jarvis):
    j = jarvis()
    run(["--socket", j.path], {"hook_event_name": "SessionStart", "session_id": "s"})
    assert wait_frames(j)[0]["payload"]["cwd"] == os.getcwd()


@pytest.mark.parametrize("shape", ["many_medium_strings", "many_keys", "long_list", "nested_big"])
def test_every_payload_shape_fits_the_frame(jarvis, shape):
    """MCP list results, a big MultiEdit, other agents' payloads: whatever the
    shape, what reaches the socket fits, keeps the event's identity, and goes
    out fast (sweep finding)."""
    if shape == "many_medium_strings":
        resp = {"items": [{"name": f"item-{i}", "body": "z" * 60} for i in range(5000)]}
    elif shape == "many_keys":
        resp = {f"key-{i}-" + "k" * 40: i for i in range(8000)}
    elif shape == "long_list":
        resp = list(range(200_000))
    else:
        resp = {"a": {"b": [{"c": "q" * 50} for _ in range(3000)]}, "d": "w" * 100_000}
    j = jarvis()
    t0 = time.monotonic()
    frame = {"jc": 1, "kind": "event", "agent": "claude", "payload": {
        "hook_event_name": "PostToolUse", "session_id": "s1", "cwd": "/w", "tool_name": "mcp__x__list",
        "tool_use_id": "toolu_1", "tool_input": {"query": "all"}, "tool_response": resp}}
    text = jc_hook._trim(frame)
    assert time.monotonic() - t0 < 0.5
    assert len(text) < jc_hook.MAX_FRAME
    p = json.loads(text)["payload"]
    assert (p["hook_event_name"], p["session_id"], p["tool_name"], p["tool_use_id"]) == (
        "PostToolUse", "s1", "mcp__x__list", "toolu_1")
    assert p["jc_trimmed"] is True


def test_stop_asks_for_a_queued_instruction_and_continues_with_it(jarvis):
    j = jarvis(reply={"decision": "block", "reason": "From the phone: run lint"})
    out, code = run(["--socket", j.path], {"hook_event_name": "Stop", "session_id": "s1", "cwd": "/w"})
    assert code == 0
    assert json.loads(out) == {"decision": "block", "reason": "From the phone: run lint"}
    assert wait_frames(j)[0]["kind"] == "stop"


def test_stop_with_nothing_queued_prints_nothing(jarvis):
    j = jarvis(reply={})
    out, _ = run(["--socket", j.path], {"hook_event_name": "Stop", "session_id": "s1", "cwd": "/w"})
    assert out == ""


def test_stop_without_jarvis_is_instant():
    import time as _t
    t0 = _t.monotonic()
    out, code = run(["--socket", "/tmp/jch-none.sock"], {"hook_event_name": "Stop", "session_id": "s"})
    assert (out, code) == ("", 0) and _t.monotonic() - t0 < 0.5
