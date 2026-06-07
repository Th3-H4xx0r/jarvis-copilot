"""Unit tests for the desktop coding-session discovery agent.

Covers the PURE ``parse_tmux_list`` (well-formed / blank lines / missing fields),
the claude/jc- filter, the on-demand ``coding_discover_request`` push, and the
change-hash throttle. A FakeRunner + fake clock keep tmux and the wall clock out.
"""
from jc_client.coding_discover import (
    CodingDiscoverAgent, parse_tmux_list, tmux_list_argv,
)


# ── pure parse_tmux_list ──────────────────────────────────────────────────────


def test_parse_tmux_list_well_formed():
    out = (
        "jc-abc\t/Users/me/proj\tclaude\t1717800000\n"
        "work\t/Users/me/other\tzsh\t1717800100\n"
    )
    rows = parse_tmux_list(out)
    assert len(rows) == 2
    assert rows[0] == {
        "tmux_name": "jc-abc", "cwd": "/Users/me/proj",
        "command": "claude", "last_activity": 1717800000.0,
    }
    assert rows[1]["command"] == "zsh"
    assert rows[1]["last_activity"] == 1717800100.0


def test_parse_tmux_list_blank_lines_skipped():
    out = "\n\njc-a\t/p\tclaude\t1\n   \n\njc-b\t/q\tclaude\t2\n\n"
    rows = parse_tmux_list(out)
    assert [r["tmux_name"] for r in rows] == ["jc-a", "jc-b"]


def test_parse_tmux_list_missing_fields_default():
    # Only a name; trailing fields absent -> "" / 0.0, not a crash.
    rows = parse_tmux_list("solo\n")
    assert rows == [{
        "tmux_name": "solo", "cwd": "", "command": "", "last_activity": 0.0,
    }]
    # Non-numeric activity falls back to 0.0.
    rows2 = parse_tmux_list("x\t/p\tclaude\tnot-a-number\n")
    assert rows2[0]["last_activity"] == 0.0


def test_parse_tmux_list_nameless_line_dropped():
    # A line whose first field is empty has no session name -> dropped.
    rows = parse_tmux_list("\t/p\tclaude\t5\n")
    assert rows == []


def test_parse_tmux_list_empty_input():
    assert parse_tmux_list("") == []
    assert parse_tmux_list(None) == []  # type: ignore[arg-type]


# ── scan filter (claude / jc-) ────────────────────────────────────────────────


class FakeRunner:
    """Records argv calls; returns scripted (rc, stdout, stderr) for tmux list."""

    def __init__(self, stdout="", rc=0, stderr=""):
        self.calls = []
        self.stdout = stdout
        self.rc = rc
        self.stderr = stderr

    def __call__(self, argv):
        self.calls.append(list(argv))
        return self.rc, self.stdout, self.stderr


class FakeClock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


_FOUR_SESSIONS = (
    "jc-abc\t/Users/me/proj\tclaude\t1717800000\n"   # claude AND jc- -> keep
    "plain-claude\t/Users/me/c\tclaude\t1717800001\n"  # claude -> keep
    "jc-launched\t/Users/me/j\tnode\t1717800002\n"     # jc- prefix -> keep
    "random\t/Users/me/r\tzsh\t1717800003\n"           # neither -> drop
)


def test_scan_keeps_only_claude_or_jc():
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=lambda f: None, device_id="dev1",
                                runner=fr, clock=FakeClock())
    sessions = agent.scan()
    names = {s["tmux_name"] for s in sessions}
    assert names == {"jc-abc", "plain-claude", "jc-launched"}
    # all in the wire shape
    for s in sessions:
        assert s["kind"] == "tmux"
        assert set(s) == {"kind", "tmux_name", "cwd", "title", "last_activity"}
    # title defaults to the cwd basename
    by_name = {s["tmux_name"]: s for s in sessions}
    assert by_name["jc-abc"]["title"] == "proj"
    # it actually ran tmux list-sessions
    assert fr.calls and fr.calls[0] == tmux_list_argv()


def test_scan_empty_on_nonzero_rc():
    fr = FakeRunner(stdout=_FOUR_SESSIONS, rc=1)  # tmux failed / no server
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, clock=FakeClock())
    assert agent.scan() == []


# ── on-demand push (coding_discover_request) ──────────────────────────────────


def _make_agent(stdout, sent, clock=None):
    fr = FakeRunner(stdout=stdout)
    agent = CodingDiscoverAgent(send=sent.append, device_id="dev1",
                                runner=fr, clock=clock or FakeClock())
    return agent, fr


def test_request_triggers_immediate_push():
    sent = []
    clock = FakeClock(2222.0)
    agent, _fr = _make_agent(_FOUR_SESSIONS, sent, clock)
    agent.handle_frame({"type": "coding_discover_request"})
    assert len(sent) == 1
    frame = sent[0]
    assert frame["type"] == "coding_discover"
    assert frame["device_id"] == "dev1"
    assert frame["scanned_at"] == 2222.0
    names = {s["tmux_name"] for s in frame["sessions"]}
    assert names == {"jc-abc", "plain-claude", "jc-launched"}


def test_request_forces_push_even_when_unchanged():
    sent = []
    agent, _fr = _make_agent(_FOUR_SESSIONS, sent)
    agent.handle_frame({"type": "coding_discover_request"})
    agent.handle_frame({"type": "coding_discover_request"})
    # force=True bypasses the change-hash throttle: two requests -> two pushes.
    assert len(sent) == 2


def test_handle_frame_ignores_unknown_and_never_raises():
    sent = []
    agent, _fr = _make_agent(_FOUR_SESSIONS, sent)
    agent.handle_frame({"type": "something_else"})
    agent.handle_frame({})  # no type at all
    assert sent == []


def test_send_failure_does_not_raise():
    def boom(_f):
        raise RuntimeError("ws closed")

    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=boom, runner=fr, clock=FakeClock())
    # Must swallow the send error rather than propagate it into the pump.
    agent.handle_frame({"type": "coding_discover_request"})


# ── change-hash throttle ──────────────────────────────────────────────────────


def test_throttle_suppresses_unchanged_polls():
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    clock = FakeClock(100.0)
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                poll_interval=0.01)
    # First (forced) scan/push establishes the baseline hash.
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    # Same set, within the heartbeat window -> suppressed.
    clock.t = 101.0
    agent._scan_and_push(force=False)
    assert len(sent) == 1


def test_throttle_pushes_when_set_changes():
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    clock = FakeClock(100.0)
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                poll_interval=0.01)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    # A new claude session appears -> the set changed -> push (no heartbeat).
    fr.stdout = _FOUR_SESSIONS + "jc-new\t/Users/me/n\tclaude\t1717800004\n"
    clock.t = 101.0
    agent._scan_and_push(force=False)
    assert len(sent) == 2
    assert {s["tmux_name"] for s in sent[1]["sessions"]} == {
        "jc-abc", "plain-claude", "jc-launched", "jc-new"}


def test_heartbeat_pushes_when_unchanged_after_interval():
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    clock = FakeClock(100.0)
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                poll_interval=0.01)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    # Same set, but past the 30s heartbeat window -> re-push for freshness.
    clock.t = 100.0 + 31.0
    agent._scan_and_push(force=False)
    assert len(sent) == 2


def test_last_activity_change_alone_does_not_repush():
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    clock = FakeClock(100.0)
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    # Only last_activity ticks (same names/cwds) -> hash unchanged -> suppressed.
    bumped = _FOUR_SESSIONS.replace("1717800000", "1717999999")
    fr.stdout = bumped
    clock.t = 101.0
    agent._scan_and_push(force=False)
    assert len(sent) == 1
