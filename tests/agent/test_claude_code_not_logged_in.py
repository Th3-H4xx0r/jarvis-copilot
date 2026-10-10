"""The `claude` CLI's "Not logged in · Please run /login" becomes "No Claude account connected".

The login probe is the primary guard; this maps the CLI's own error when the
probe was optimistic. All subprocess calls are mocked.
"""

import json
import threading
from unittest import mock

import pytest

from agent.claude_code_client import ClaudeCodeClient
from agent.error_classifier import NO_CLAUDE_ACCOUNT, FailoverReason, classify_api_error

NOT_LOGGED_IN = "Not logged in · Please run /login"


def _cp(stdout="", stderr="", returncode=0):
    cp = mock.Mock()
    cp.stdout = stdout
    cp.stderr = stderr
    cp.returncode = returncode
    return cp


def _create(cp):
    c = ClaudeCodeClient()
    with mock.patch("agent.claude_code_client.subprocess.run", return_value=cp):
        with pytest.raises(RuntimeError) as excinfo:
            c.chat.completions.create(
                model="claude-sonnet-5-5", messages=[{"role": "user", "content": "hi"}]
            )
    return excinfo.value


def _assert_mapped(err):
    msg = str(err)
    assert msg.startswith(NO_CLAUDE_ACCOUNT)
    assert "Please run /login" not in msg
    assert classify_api_error(err).reason is FailoverReason.missing_credential


@pytest.mark.parametrize(
    "cp",
    [
        _cp(json.dumps({"type": "result", "is_error": True, "result": NOT_LOGGED_IN})),
        _cp("", stderr="Error: Not logged in", returncode=1),
        _cp(NOT_LOGGED_IN, returncode=1),
        _cp(json.dumps({"type": "result", "is_error": True, "result": "Invalid API key · Please run /login"})),
    ],
)
def test_create_maps_not_logged_in(cp):
    _assert_mapped(_create(cp))


def test_other_cli_errors_keep_their_text():
    err = _create(_cp(json.dumps({"type": "result", "is_error": True, "result": "You're out of extra usage."})))
    assert "out of extra usage" in str(err)
    assert NO_CLAUDE_ACCOUNT not in str(err)


class _FakePopen:
    def __init__(self, lines, stderr=""):
        self.stdin = mock.Mock()
        self.stderr = mock.Mock()
        self.stderr.read = lambda: stderr
        self.stdout = iter(line + "\n" for line in lines)

    def poll(self):
        return 0

    def terminate(self):
        pass

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass


def _stream(lines, stderr=""):
    c = ClaudeCodeClient()
    with mock.patch("agent.claude_code_client.subprocess.Popen", return_value=_FakePopen(lines, stderr)):
        with pytest.raises(RuntimeError) as excinfo:
            list(c.chat.completions.create(
                stream=True, model="claude-sonnet-5-5",
                messages=[{"role": "user", "content": "hi"}],
            ))
    return excinfo.value


def test_stream_maps_not_logged_in_result():
    _assert_mapped(_stream([
        json.dumps({"type": "system", "subtype": "init"}),
        json.dumps({"type": "result", "is_error": True, "result": NOT_LOGGED_IN}),
    ]))


def test_stream_maps_not_logged_in_on_plain_output():
    _assert_mapped(_stream([NOT_LOGGED_IN]))


def test_stream_maps_not_logged_in_from_stderr():
    _assert_mapped(_stream([], stderr="Not logged in"))


# ── structured engine ───────────────────────────────────────────────────────


def test_structured_turn_reports_not_logged_in_as_an_error_without_streaming_it():
    from agent.claude_code_structured import _consume_turn

    lines = [
        json.dumps({"type": "system", "subtype": "init", "session_id": "s1"}),
        json.dumps({
            "type": "assistant",
            "error": "authentication_failed",
            "message": {"model": "<synthetic>",
                        "content": [{"type": "text", "text": NOT_LOGGED_IN}]},
        }),
        json.dumps({"type": "result", "is_error": True, "result": NOT_LOGGED_IN}),
    ]
    proc = mock.Mock()
    proc.stdout = iter(line + "\n" for line in lines)
    streamed = []
    res = _consume_turn(proc, timeout=30, on_text=streamed.append,
                        aborted=threading.Event(), state={})

    assert res.is_error is True
    assert res.text == ""
    assert res.error.startswith(NO_CLAUDE_ACCOUNT)
    assert streamed == []


def test_structured_turn_keeps_a_real_reply_that_mentions_login():
    from agent.claude_code_structured import _consume_turn

    reply = "To sign in, open Claude Code. Please run /login there."
    lines = [
        json.dumps({"type": "assistant", "message": {
            "model": "claude-sonnet-5-5", "content": [{"type": "text", "text": reply}]}}),
        json.dumps({"type": "result", "is_error": False, "result": reply}),
    ]
    proc = mock.Mock()
    proc.stdout = iter(line + "\n" for line in lines)
    res = _consume_turn(proc, timeout=30, on_text=None, aborted=threading.Event(), state={})
    assert res.is_error is False
    assert res.text == reply


def test_structured_turn_drops_an_untagged_login_message():
    """An older CLI may not mark its synthetic message — still not a reply."""
    from agent.claude_code_structured import _consume_turn

    lines = [
        json.dumps({"type": "assistant", "message": {
            "model": "claude-sonnet-5-5", "content": [{"type": "text", "text": NOT_LOGGED_IN}]}}),
        json.dumps({"type": "result", "is_error": True, "result": NOT_LOGGED_IN}),
    ]
    proc = mock.Mock()
    proc.stdout = iter(line + "\n" for line in lines)
    res = _consume_turn(proc, timeout=30, on_text=None, aborted=threading.Event(), state={})
    assert res.is_error is True
    assert res.text == ""
    assert res.error.startswith(NO_CLAUDE_ACCOUNT)


def test_structured_other_errors_keep_their_text():
    from agent.claude_code_structured import _consume_turn

    lines = [json.dumps({"type": "result", "is_error": True, "result": "API Error: 529 Overloaded"})]
    proc = mock.Mock()
    proc.stdout = iter(line + "\n" for line in lines)
    res = _consume_turn(proc, timeout=30, on_text=None, aborted=threading.Event(), state={})
    assert res.error == "API Error: 529 Overloaded"
