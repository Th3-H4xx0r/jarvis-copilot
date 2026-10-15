"""jc-client's hook server: jc-hook frames in → engine + bridge + island."""
import json
import os
import shutil
import socket
import stat
import tempfile
import threading
import time

import pytest

from jc_client import agent_engine
from jc_client.hook_server import HookServer


@pytest.fixture
def sockdir():
    d = tempfile.mkdtemp(dir="/tmp", prefix="jhs")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def send(path, frame, wait=False):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(path)
    s.sendall((frame if isinstance(frame, str) else json.dumps(frame)).encode() + b"\n")
    reply = b""
    if wait:
        while b"\n" not in reply:
            chunk = s.recv(4096)
            if not chunk:
                break
            reply += chunk
    s.close()
    return json.loads(reply) if reply.strip() else None


def until(cond, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return False


def frame(kind, payload, agent="claude"):
    return {"jc": 1, "kind": kind, "agent": agent, "payload": payload}


def test_event_reaches_engine_forward_and_island(sockdir):
    eng = agent_engine.Engine()
    forwarded, effects = [], []
    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=forwarded.append,
                    on_effects=effects.extend)
    hs.start()
    try:
        send(hs.path, frame("event", {"hook_event_name": "UserPromptSubmit", "session_id": "s",
                                      "cwd": "/w/app", "prompt": "hi"}))
        assert until(lambda: forwarded and effects)
        assert eng.sessions()[0]["state"] == "thinking"
        f = forwarded[0]
        assert f["type"] == "event" and f["name"] == "agent_hook"
        assert f["data"]["kind"] == "event" and f["data"]["agent"] == "claude"
        assert f["data"]["payload"]["prompt"] == "hi"
        assert effects[0]["kind"] == "state"
    finally:
        hs.close()


def test_socket_is_owner_only(sockdir):
    hs = HookServer(os.path.join(sockdir, "h.sock"), agent_engine.Engine(), forward=lambda f: None)
    hs.start()
    try:
        assert stat.S_IMODE(os.stat(hs.path).st_mode) == 0o600
    finally:
        hs.close()


def test_stale_socket_file_is_replaced(sockdir):
    path = os.path.join(sockdir, "h.sock")
    open(path, "w").close()
    hs = HookServer(path, agent_engine.Engine(), forward=lambda f: None)
    hs.start()
    try:
        send(path, frame("event", {"hook_event_name": "SessionStart", "session_id": "s", "cwd": "/w"}))
        assert until(lambda: hs.engine_sessions())
    finally:
        hs.close()


def test_forward_failure_never_breaks_the_hook(sockdir):
    def boom(_f):
        raise ConnectionError("bridge down")
    eng = agent_engine.Engine()
    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=boom)
    hs.start()
    try:
        send(hs.path, frame("event", {"hook_event_name": "SessionStart", "session_id": "s", "cwd": "/w"}))
        assert until(lambda: eng.sessions())
    finally:
        hs.close()


def test_permission_without_arbiter_answers_ask_and_marks_approval(sockdir):
    eng = agent_engine.Engine()
    forwarded = []
    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=forwarded.append)
    hs.start()
    try:
        reply = send(hs.path, frame("permission", {"hook_event_name": "PermissionRequest",
                                                   "session_id": "s", "cwd": "/w",
                                                   "tool_name": "Bash", "tool_use_id": "t",
                                                   "tool_input": {"command": "ls"}}), wait=True)
        assert reply == {"decision": "ask"}
        assert eng.sessions()[0]["state"] == "approval"
        assert forwarded[0]["data"]["kind"] == "permission"
    finally:
        hs.close()


def test_blocking_frame_goes_to_the_arbiter(sockdir):
    class Arb:
        def __init__(self):
            self.calls = []

        def submit(self, kind, agent, payload, key, reply):
            self.calls.append((kind, key))
            threading.Timer(0.05, reply, args=({"decision": "allow"},)).start()

        def observe(self, payload, key):
            pass

    arb = Arb()
    hs = HookServer(os.path.join(sockdir, "h.sock"), agent_engine.Engine(),
                    forward=lambda f: None, arbiter=arb)
    hs.start()
    try:
        reply = send(hs.path, frame("ask", {"hook_event_name": "PreToolUse", "session_id": "s",
                                            "cwd": "/w", "tool_name": "AskUserQuestion",
                                            "tool_input": {"questions": []}}), wait=True)
        assert reply == {"decision": "allow"}
        assert arb.calls == [("ask", agent_engine.session_key("local", "claude", "s", "/w"))]
    finally:
        hs.close()


def test_malformed_lines_are_ignored(sockdir):
    eng = agent_engine.Engine()
    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=lambda f: None)
    hs.start()
    try:
        send(hs.path, "not json")
        send(hs.path, json.dumps({"jc": 1, "kind": "event", "payload": "nope"}))
        send(hs.path, frame("event", {"hook_event_name": "SessionStart", "session_id": "ok", "cwd": "/w"}))
        assert until(lambda: [s["session_id"] for s in eng.sessions()] == ["ok"])
    finally:
        hs.close()


def test_statusline_goes_to_usage_not_engine(sockdir):
    eng = agent_engine.Engine()
    usage, forwarded = [], []
    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=forwarded.append,
                    on_usage=usage.append)
    hs.start()
    try:
        limits = {"five_hour": {"used_percentage": 12, "resets_at": 1}}
        send(hs.path, frame("statusline", {"session_id": "s", "rate_limits": limits}))
        assert until(lambda: usage)
        assert usage[0]["rate_limits"] == limits
        assert eng.sessions() == []
        assert forwarded[0]["data"]["kind"] == "statusline"
    finally:
        hs.close()


def test_external_ingest_replaces_the_engine(sockdir):
    seen = []

    def ingest(kind, agent, payload):
        seen.append((kind, agent, payload["hook_event_name"]))
        return [{"kind": "state", "key": "k"}]

    effects = []
    hs = HookServer(os.path.join(sockdir, "h.sock"), None, forward=lambda f: None,
                    ingest=ingest, on_effects=effects.extend, host="server", sweep_every=0)
    hs.start()
    try:
        reply = send(hs.path, frame("permission", {"hook_event_name": "PermissionRequest",
                                                   "session_id": "s", "cwd": "/w"}), wait=True)
        assert reply == {"decision": "ask"}
        assert seen == [("permission", "claude", "PermissionRequest")]
        assert effects == [{"kind": "state", "key": "k"}]
    finally:
        hs.close()


def test_sweep_runs_on_a_timer(sockdir):
    class Clock:
        t = 1000.0

        def __call__(self):
            return self.t

    clock = Clock()
    eng = agent_engine.Engine(clock=clock)
    effects = []
    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=lambda f: None,
                    on_effects=effects.extend, sweep_every=0.05)
    hs.start()
    try:
        send(hs.path, frame("event", {"hook_event_name": "Stop", "session_id": "s", "cwd": "/w"}))
        assert until(lambda: eng.sessions() and eng.sessions()[0]["state"] == "finished")
        clock.t += 10
        assert until(lambda: eng.sessions()[0]["state"] == "idle")
    finally:
        hs.close()


def test_identical_requests_get_their_own_fingerprints(sockdir):
    """Claude's PermissionRequest has no tool_use_id: two parallel `npm test`
    asks must still be two requests, each answered on its own (sweep finding)."""
    from jc_client.approval_arbiter import Arbiter
    ups = []
    arb = Arbiter(send_up=ups.append, gate=lambda: True)
    forwarded = []
    hs = HookServer(os.path.join(sockdir, "h.sock"), agent_engine.Engine(),
                    forward=forwarded.append, arbiter=arb)
    hs.start()
    replies = []
    try:
        p = {"hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/w",
             "tool_name": "Bash", "tool_input": {"command": "npm test"}}
        for _ in range(2):
            threading.Thread(target=lambda: replies.append(send(hs.path, frame("permission", dict(p)), wait=True)),
                             daemon=True).start()
        assert until(lambda: len(arb.pending()) == 2)
        fps = {e["fingerprint"] for e in arb.pending()}
        assert len(fps) == 2
        # What goes up to the server carries the same stamp, so it agrees.
        up_fps = {agent_engine.fingerprint(f["data"]["payload"]["session_id"], f["data"]["payload"]["tool_use_id"],
                                           "Bash", {"command": "npm test"})
                  for f in forwarded if f["data"]["kind"] == "permission"}
        assert up_fps == fps
        first = sorted(fps)[0]
        assert arb.decide(first, "allow") is True
        assert until(lambda: len(replies) == 1)
        assert [e["fingerprint"] for e in arb.pending()] == [sorted(fps)[1]]
        assert arb.decide(sorted(fps)[1], "deny") is True
        assert until(lambda: len(replies) == 2)
    finally:
        hs.close()


def test_stop_is_an_event_that_also_gets_an_answer(sockdir):
    """A Stop ingests like any event and is answered with what waits for the
    session (a phone message), or {}."""
    eng = agent_engine.Engine()
    asked = []

    def on_stop(agent, payload):
        asked.append((agent, payload.get("session_id")))
        return {"decision": "block", "reason": "From the phone: run lint"} if payload.get("session_id") == "s1" else None

    hs = HookServer(os.path.join(sockdir, "h.sock"), eng, forward=lambda f: None, on_stop=on_stop)
    hs.start()
    try:
        reply = send(hs.path, frame("stop", {"hook_event_name": "Stop", "session_id": "s1", "cwd": "/w"}), wait=True)
        assert reply == {"decision": "block", "reason": "From the phone: run lint"}
        assert eng.session(agent_engine.session_key("local", "claude", "s1", "/w")) is not None
        assert send(hs.path, frame("stop", {"hook_event_name": "Stop", "session_id": "s2", "cwd": "/w"}),
                    wait=True) == {}
        assert asked == [("claude", "s1"), ("claude", "s2")]
    finally:
        hs.close()
