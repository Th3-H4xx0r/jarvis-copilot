"""CodexRuntime drives `codex app-server` (newline-delimited JSON-RPC over
stdio) to continue a Codex session on the server: resume a thread, send turns,
surface + answer approval requests. Everything here runs against a scripted
fake app-server — no real Codex, no network."""
import json
import queue
import subprocess
import time

import pytest

from agent.codex_server_runtime import CodexRuntime, DeliveryError

BIN = "/opt/codex/bin/codex"


class _Out:
    """The fake child's stdout: a blocking line iterator."""

    def __init__(self):
        self.q: queue.Queue = queue.Queue()

    def __iter__(self):
        return self

    def __next__(self):
        line = self.q.get()
        if line is None:
            raise StopIteration
        return line


class _In:
    def __init__(self, server):
        self.server, self.closed = server, False

    def write(self, s):
        if self.closed or self.server.returncode is not None:
            raise BrokenPipeError("pipe closed")
        self.server.feed(s)
        return len(s)

    def flush(self):
        pass

    def close(self):
        self.closed = True
        self.server.die(0)


def _ok(result):
    return lambda params: ("result", result(params) if callable(result) else result)


DEFAULT_HANDLERS = {
    "initialize": _ok({"userAgent": "fake/0.163.0", "codexHome": "/x/.codex"}),
    "thread/resume": _ok(lambda p: {"thread": {"id": p["threadId"]}}),
    "thread/start": _ok({"thread": {"id": "th-new"}}),
    "turn/start": _ok({"turn": {"id": "tu-1", "status": "inProgress"}}),
}


class FakeAppServer:
    """Scripted stand-in for the `codex app-server` child process."""

    def __init__(self, argv, kwargs, handlers):
        self.argv, self.kwargs, self.handlers = argv, kwargs, handlers
        self.sent: list[dict] = []
        self.raw = ""
        self.stdout, self.stdin, self.stderr = _Out(), _In(self), None
        self.returncode = None
        self._buf = ""

    def feed(self, s):
        self.raw += s
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            msg = json.loads(line)
            self.sent.append(msg)
            if "method" in msg and "id" in msg:
                handler = self.handlers.get(msg["method"])
                reply = handler(msg.get("params") or {}) if handler else (
                    "error", {"code": -32601, "message": "unknown method"})
                if reply is not None:
                    kind, body = reply
                    self.emit({"id": msg["id"], kind: body})

    def emit(self, obj):
        self.stdout.q.put(json.dumps(obj) + "\n")

    def die(self, code=0):
        if self.returncode is None:
            self.returncode = code
            self.stdout.q.put(None)

    def poll(self):
        return self.returncode

    def terminate(self):
        self.die(-15)

    def kill(self):
        self.die(-9)

    def wait(self, timeout=None):
        return self.returncode

    def methods(self):
        return [m.get("method") for m in self.sent]

    def replies(self):
        return [m for m in self.sent if "method" not in m]


class Spawner:
    def __init__(self, **handlers):
        self.handlers = {**DEFAULT_HANDLERS, **handlers}
        self.procs: list[FakeAppServer] = []

    def __call__(self, argv, **kwargs):
        p = FakeAppServer(argv, kwargs, self.handlers)
        self.procs.append(p)
        return p


def _logged_in_run(*calls):
    def run(argv, **kwargs):
        calls[0].append((argv, kwargs)) if calls else None
        return subprocess.CompletedProcess(argv, 0, "Logged in using ChatGPT\n", "")
    return run


def _runtime(tmp_path, spawner=None, run=None, which=lambda name: BIN, **kw):
    return CodexRuntime(run=run or _logged_in_run(), popen=spawner or Spawner(),
                        which=which, home=tmp_path, **kw)


def _until(pred, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(0.01)
    raise AssertionError("condition not met in time")


# ── availability ────────────────────────────────────────────────────────────

def test_unavailable_when_missing(tmp_path):
    rt = _runtime(tmp_path, which=lambda name: None)
    assert rt.available() == (False, "Codex isn't installed on the server")
    with pytest.raises(DeliveryError, match="isn't installed"):
        rt.start(str(tmp_path), resume_session_id="th-1")


def test_unavailable_when_not_logged_in(tmp_path):
    calls = []

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        return subprocess.CompletedProcess(argv, 1, "Not logged in\n", "")

    rt = _runtime(tmp_path, run=run)
    assert rt.available() == (
        False, "Codex isn't logged in on the server — run `codex login` there")
    assert calls[0][0] == [BIN, "login", "status"]


def test_available_when_logged_in(tmp_path):
    assert _runtime(tmp_path).available() == (True, "")


def test_unavailable_when_login_check_crashes(tmp_path):
    def run(argv, **kwargs):
        raise subprocess.TimeoutExpired(argv, 15)

    ok, why = _runtime(tmp_path, run=run).available()
    assert ok is False and why


# ── subprocess hygiene ──────────────────────────────────────────────────────

def test_no_shell_in_argv(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-should-not-leak")
    monkeypatch.setenv("GITHUB_TOKEN", "ghp-should-not-leak")
    monkeypatch.setenv("SOME_SECRET", "nope")
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    run_calls = []
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner, run=_logged_in_run(run_calls))
    rt.available()
    rt.start(str(tmp_path), resume_session_id="th-1")
    calls = [(a, k) for a, k in run_calls] + [(p.argv, p.kwargs) for p in spawner.procs]
    assert calls
    for argv, kwargs in calls:
        assert isinstance(argv, list) and argv[0] == BIN
        assert not kwargs.get("shell")
        env = kwargs["env"]
        assert "OPENAI_API_KEY" not in env and "GITHUB_TOKEN" not in env
        assert "SOME_SECRET" not in env
        assert env["HOME"] == str(tmp_path) and env["PATH"] == "/usr/bin:/bin"
    proc = spawner.procs[0]
    assert proc.argv == [BIN, "app-server"]
    assert proc.kwargs["cwd"] == str(tmp_path)


# ── protocol framing ────────────────────────────────────────────────────────

def test_resume_handshake_framing(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    handle = rt.start("/work/demo", resume_session_id="th-1", model="gpt-test")
    assert handle == "th-1"
    proc = spawner.procs[0]
    # Newline-delimited JSON, one message per line.
    assert proc.raw.endswith("\n") and all(json.loads(x) for x in proc.raw.splitlines())
    init, inited, resume = proc.sent[:3]
    assert init["method"] == "initialize" and "id" in init
    assert init["params"]["clientInfo"]["name"]
    assert inited == {"method": "initialized"}        # a notification: no id
    assert resume["method"] == "thread/resume"
    assert resume["params"]["threadId"] == "th-1"
    assert resume["params"]["cwd"] == "/work/demo"
    assert resume["params"]["model"] == "gpt-test"
    assert resume["params"]["approvalPolicy"] == "on-request"


def test_start_new_thread_with_prompt(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    handle = rt.start("/work/demo", prompt="Say READY")
    assert handle == "th-new"
    proc = spawner.procs[0]
    assert proc.methods()[:4] == ["initialize", "initialized", "thread/start", "turn/start"]
    turn = proc.sent[3]
    assert turn["params"]["threadId"] == "th-new"
    assert turn["params"]["input"] == [{"type": "text", "text": "Say READY",
                                        "text_elements": []}]


def test_send_turn(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    h = rt.start("/w", resume_session_id="th-1")
    rt.send(h, "next step please")
    turn = spawner.procs[0].sent[-1]
    assert turn["method"] == "turn/start"
    assert turn["params"]["input"][0]["text"] == "next step please"


def test_send_failure_raises_delivery_error(tmp_path):
    spawner = Spawner(**{"turn/start": lambda p: (
        "error", {"code": -32600, "message": "thread not loaded"})})
    rt = _runtime(tmp_path, spawner=spawner)
    h = rt.start("/w", resume_session_id="th-1")
    with pytest.raises(DeliveryError, match="thread not loaded"):
        rt.send(h, "hello")
    with pytest.raises(DeliveryError):
        rt.send("no-such-handle", "hello")
    with pytest.raises(DeliveryError):
        rt.send(h, "   ")


def test_send_times_out_when_codex_never_answers(tmp_path):
    spawner = Spawner(**{"turn/start": lambda p: None})
    rt = _runtime(tmp_path, spawner=spawner)
    h = rt.start("/w", resume_session_id="th-1")
    with pytest.raises(DeliveryError, match="didn't"):
        rt.send(h, "hello", timeout=0.2)


def test_resume_failure_raises_and_cleans_up(tmp_path):
    spawner = Spawner(**{"thread/resume": lambda p: (
        "error", {"code": -32600, "message": "no rollout found for thread id"})})
    rt = _runtime(tmp_path, spawner=spawner)
    with pytest.raises(DeliveryError, match="no rollout found"):
        rt.start("/w", resume_session_id="gone")
    assert spawner.procs[0].returncode is not None


def test_send_respawns_dead_app_server(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    h = rt.start("/w", resume_session_id="th-1")
    spawner.procs[0].die(1)
    rt.send(h, "still there?")
    assert len(spawner.procs) == 2
    assert spawner.procs[1].methods() == ["initialize", "initialized",
                                          "thread/resume", "turn/start"]


def test_stop_terminates_and_forgets(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    h = rt.start("/w", resume_session_id="th-1")
    rt.stop(h)
    assert spawner.procs[0].returncode is not None
    with pytest.raises(DeliveryError):
        rt.send(h, "hello")
    rt.stop(h)        # idempotent


# ── approvals ───────────────────────────────────────────────────────────────

def test_command_approval_roundtrip(tmp_path):
    events = []
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner, on_event=lambda k, d: events.append((k, d)))
    h = rt.start("/w", resume_session_id="th-1")
    proc = spawner.procs[0]
    # Server→client request ids are per-process counters that start at 0.
    proc.emit({"id": 0, "method": "item/commandExecution/requestApproval",
               "params": {"threadId": "th-1", "turnId": "tu-1", "itemId": "ex-1",
                          "command": "/bin/zsh -lc 'touch a.txt'", "cwd": "/w",
                          "reason": "needs write access", "startedAtMs": 1}})
    pending = _until(rt.pending_approvals)
    assert len(pending) == 1
    ap = pending[0]
    assert ap["handle"] == h and ap["kind"] == "command"
    assert ap["command"] == "touch a.txt" and ap["reason"] == "needs write access"
    assert any(k == "approval" for k, _ in events)
    assert rt.answer_approval(ap["id"], "allow") is True
    assert proc.replies()[-1] == {"id": 0, "result": {"decision": "accept"}}
    assert rt.pending_approvals() == []
    assert rt.answer_approval(ap["id"], "allow") is False


def test_file_change_and_mcp_approvals_deny(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    rt.start("/w", resume_session_id="th-1")
    proc = spawner.procs[0]
    proc.emit({"method": "item/started", "params": {"threadId": "th-1", "item": {
        "type": "fileChange", "id": "fc-1", "status": "inProgress",
        "changes": [{"path": "/w/a.py", "kind": {"type": "update"}, "diff": "@@"}]}}})
    proc.emit({"id": 1, "method": "item/fileChange/requestApproval",
               "params": {"threadId": "th-1", "turnId": "tu-1", "itemId": "fc-1",
                          "startedAtMs": 1}})
    proc.emit({"id": 2, "method": "mcpServer/elicitation/request",
               "params": {"threadId": "th-1", "serverName": "memory", "mode": "form",
                          "message": "Allow memory to run tool \"recall\"?",
                          "requestedSchema": {"type": "object", "properties": {}},
                          "_meta": {"codex_approval_kind": "mcp_tool_call"}}})
    pending = _until(lambda: len(rt.pending_approvals()) == 2 and rt.pending_approvals())
    by_kind = {a["kind"]: a for a in pending}
    assert by_kind["file_change"]["files"] == ["/w/a.py"]
    assert "recall" in by_kind["mcp_tool"]["title"]
    assert rt.answer_approval(by_kind["file_change"]["id"], "deny") is True
    assert rt.answer_approval(by_kind["mcp_tool"]["id"], "deny") is True
    assert {"id": 1, "result": {"decision": "decline"}} in proc.replies()
    assert {"id": 2, "result": {"action": "decline"}} in proc.replies()
    assert rt.answer_approval("whatever", "maybe") is False


def test_resolved_elsewhere_clears_pending(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    rt.start("/w", resume_session_id="th-1")
    proc = spawner.procs[0]
    proc.emit({"id": 5, "method": "item/commandExecution/requestApproval",
               "params": {"threadId": "th-1", "turnId": "t", "itemId": "i",
                          "command": "rm -rf build", "startedAtMs": 1}})
    _until(rt.pending_approvals)
    proc.emit({"method": "serverRequest/resolved",
               "params": {"threadId": "th-1", "requestId": 5}})
    _until(lambda: rt.pending_approvals() == [])


def test_unsupported_server_request_gets_an_error_reply(tmp_path):
    spawner = Spawner()
    rt = _runtime(tmp_path, spawner=spawner)
    rt.start("/w", resume_session_id="th-1")
    proc = spawner.procs[0]
    proc.emit({"id": 9, "method": "item/tool/requestUserInput",
               "params": {"threadId": "th-1"}})
    reply = _until(lambda: next((m for m in proc.replies() if m.get("id") == 9), None))
    assert "error" in reply
    assert rt.pending_approvals() == []
