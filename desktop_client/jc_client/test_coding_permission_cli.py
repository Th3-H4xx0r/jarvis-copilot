"""jc-client coding-permission: the PreToolUse permission-relay decision logic
(POST request -> poll for verdict -> print the permissionDecision JSON), with
the HTTP + credentials mocked. The key contract: NEVER auto-allow on any
failure; fall back to 'ask'/defer."""
import json
import time
import types

from jc_client import cli, credentials
import jc_client.protocol as protocol


class _Resp:
    def __init__(self, data):
        self._d = data

    def json(self):
        return self._d


def _paired(monkeypatch):
    creds = types.SimpleNamespace(
        paired=True, server_url="https://x", cookie="c", cert_fingerprint="f",
        cf_client_id="", cf_client_secret="", device_id="d")
    monkeypatch.setattr(credentials, "load", lambda: creds)
    monkeypatch.setattr(time, "sleep", lambda *_a, **_k: None)


def _args(**kw):
    base = dict(tool="Bash", input='{"command":"ls"}', tmux="", cwd="/w",
                session_id="", timeout=5.0)
    base.update(kw)
    return types.SimpleNamespace(**base)


def _run(monkeypatch, request_resp, poll_resp):
    class FH:
        def __init__(self, *a, **k):
            pass

        def request_json(self, method, path, body=None):
            if path == "/api/coding/permission/request":
                return _Resp(request_resp)
            if path.startswith("/api/coding/permission/poll"):
                return _Resp(poll_resp)
            return _Resp({})
    monkeypatch.setattr(protocol, "HttpClient", FH)


def test_allow(monkeypatch, capsys):
    _paired(monkeypatch)
    _run(monkeypatch, {"request_id": "r1", "notified": 1},
         {"status": "resolved", "decision": "allow"})
    assert cli.cmd_coding_permission(_args()) == 0
    j = json.loads(capsys.readouterr().out)
    assert j["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_deny_with_reason(monkeypatch, capsys):
    _paired(monkeypatch)
    _run(monkeypatch, {"request_id": "r1", "notified": 1},
         {"status": "resolved", "decision": "deny", "reason": "use src/"})
    cli.cmd_coding_permission(_args())
    j = json.loads(capsys.readouterr().out)
    assert j["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert j["hookSpecificOutput"]["permissionDecisionReason"] == "use src/"


def test_disabled_defers_silently(monkeypatch, capsys):
    _paired(monkeypatch)
    _run(monkeypatch, {"disabled": True, "request_id": None, "notified": 0}, {})
    assert cli.cmd_coding_permission(_args()) == 0
    assert capsys.readouterr().out.strip() == ""   # nothing → Claude's normal flow


def test_no_device_defers_silently(monkeypatch, capsys):
    _paired(monkeypatch)
    _run(monkeypatch, {"request_id": "r1", "notified": 0}, {})
    cli.cmd_coding_permission(_args())
    assert capsys.readouterr().out.strip() == ""


def test_expired_falls_back_to_ask(monkeypatch, capsys):
    _paired(monkeypatch)
    _run(monkeypatch, {"request_id": "r1", "notified": 1},
         {"status": "expired"})
    cli.cmd_coding_permission(_args())
    j = json.loads(capsys.readouterr().out)
    assert j["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_unpaired_defers(monkeypatch, capsys):
    monkeypatch.setattr(credentials, "load",
                        lambda: types.SimpleNamespace(paired=False))
    assert cli.cmd_coding_permission(_args()) == 0
    assert capsys.readouterr().out.strip() == ""


def test_timeout_falls_back_to_ask(monkeypatch, capsys):
    _paired(monkeypatch)
    # poll always pending; timeout is tiny so the loop exits → ask
    _run(monkeypatch, {"request_id": "r1", "notified": 1},
         {"status": "pending"})
    cli.cmd_coding_permission(_args(timeout=0.01))
    j = json.loads(capsys.readouterr().out)
    assert j["hookSpecificOutput"]["permissionDecision"] == "ask"
