"""Unit tests for the desktop coding-session discovery agent.

Covers the PURE ``parse_tmux_list`` (well-formed / blank lines / missing fields),
the claude/jc- filter, the on-demand ``coding_discover_request`` push, the
change-hash throttle, the PURE ``scan_transcripts`` (Claude Code session store) +
its integration into the combined push, the junk-discovery filters (hidden /
nonexistent cwds), and the ``coding_transcript_get`` -> ``coding_transcript_data``
streaming. A FakeRunner + fake clock keep tmux and the wall clock out; an injected
``home_dir`` keeps the real ``~/.claude`` out.

NOTE: discovery now drops any session/transcript whose cwd isn't an existing,
non-hidden directory, so tests point cwds at REAL dirs created under ``_REAL_BASE``
(not fictional ``/Users/me/...`` paths).
"""
import base64
import gzip
import json
import os
import tempfile
import threading

from jc_client.coding_discover import (
    CodingDiscoverAgent, parse_tmux_list, scan_transcripts, tmux_list_argv,
)

# A shared EMPTY home dir: no ``.claude/projects``, so ``scan_transcripts``
# returns ``[]``. The tmux-only tests pass this so they never pick up the real
# ~/.claude (which would inject transcript items and break tmux_name asserts).
_EMPTY_HOME = tempfile.mkdtemp(prefix="jc-discover-empty-home-")

# A base of REAL directories. The discovery filters drop any session/transcript
# whose cwd isn't an existing, non-hidden directory, so test cwds live here.
_REAL_BASE = tempfile.mkdtemp(prefix="jc-discover-real-")


def _real(*names) -> str:
    """Create (idempotently) and return a real directory path under _REAL_BASE."""
    p = os.path.join(_REAL_BASE, *names)
    os.makedirs(p, exist_ok=True)
    return p


# Canonical four-session tmux fixture, with REAL cwds for the kept sessions.
_CWD_PROJ = _real("proj")   # jc-abc
_CWD_C = _real("c")         # plain-claude
_CWD_J = _real("j")         # jc-launched

_FOUR_SESSIONS = (
    f"jc-abc\t{_CWD_PROJ}\tclaude\t1717800000\n"     # claude AND jc- -> keep
    f"plain-claude\t{_CWD_C}\tclaude\t1717800001\n"   # claude -> keep
    f"jc-launched\t{_CWD_J}\tnode\t1717800002\n"      # jc- prefix -> keep
    "random\t/Users/me/r\tzsh\t1717800003\n"          # neither -> drop (cmd filter)
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


def test_scan_keeps_only_claude_or_jc():
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=lambda f: None, device_id="dev1",
                                runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    sessions = agent.scan()
    names = {s["tmux_name"] for s in sessions}
    assert names == {"jc-abc", "plain-claude", "jc-launched"}
    # all in the wire shape
    for s in sessions:
        assert s["kind"] == "tmux"
        assert set(s) == {"kind", "tmux_name", "cwd", "title",
                          "last_activity", "activity_state"}
    # title defaults to the cwd basename
    by_name = {s["tmux_name"]: s for s in sessions}
    assert by_name["jc-abc"]["title"] == "proj"
    # it actually ran tmux list-sessions
    assert fr.calls and fr.calls[0] == tmux_list_argv()


def test_scan_empty_on_nonzero_rc():
    fr = FakeRunner(stdout=_FOUR_SESSIONS, rc=1)  # tmux failed / no server
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    assert agent.scan() == []


def test_scan_keeps_claude_launched_by_absolute_path():
    # tmux can report pane_current_command as a full path when claude is started
    # by absolute path; the basename is still "claude" -> must be kept.
    out = (
        f"abs\t{_real('a')}\t/usr/local/bin/claude\t1\n"  # path to claude -> keep
        f"node-only\t{_real('n')}\tnode\t2\n"             # bare node -> drop
        f"zsh-only\t{_real('z')}\t/bin/zsh\t3\n"          # path to zsh -> drop
    )
    fr = FakeRunner(stdout=out)
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    names = {s["tmux_name"] for s in agent.scan()}
    assert names == {"abs"}


# ── junk-discovery filters (hidden / nonexistent cwd) ─────────────────────────


def test_scan_skips_hidden_and_nonexistent_tmux_cwd():
    # A claude/jc- session in a hidden dir, and one whose cwd no longer exists,
    # are both dropped; only the real visible-dir session is kept.
    hidden = _real(".HIDDEN")                     # real dir, but hidden basename
    real = _real("realwork")
    gone = os.path.join(_REAL_BASE, "does-not-exist-xyz")  # never created
    out = (
        f"jc-hidden\t{hidden}\tclaude\t1\n"
        f"jc-gone\t{gone}\tclaude\t2\n"
        f"jc-real\t{real}\tclaude\t3\n"
    )
    fr = FakeRunner(stdout=out)
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    names = {s["tmux_name"] for s in agent.scan()}
    assert names == {"jc-real"}


def test_scan_transcripts_skips_hidden_and_nonexistent_cwd(tmp_path):
    # Transcripts whose recorded cwd is hidden or has been deleted must NOT
    # resurrect as projects; only the real visible-dir transcript survives.
    home = str(tmp_path)
    real = _real("twork")
    hidden = _real(".secret")
    gone = os.path.join(_REAL_BASE, "transcript-gone-xyz")  # never created
    _write_transcript(home, "p1", "real-id", [_cwd_line(real)])
    _write_transcript(home, "p2", "hidden-id", [_cwd_line(hidden)])
    _write_transcript(home, "p3", "gone-id", [_cwd_line(gone)])
    items = scan_transcripts(home, now=1000.0)
    ids = {it["claude_session_id"] for it in items}
    assert ids == {"real-id"}


# ── on-demand push (coding_discover_request) ──────────────────────────────────


def _make_agent(stdout, sent, clock=None, home_dir=_EMPTY_HOME):
    fr = FakeRunner(stdout=stdout)
    agent = CodingDiscoverAgent(send=sent.append, device_id="dev1",
                                runner=fr, clock=clock or FakeClock(),
                                home_dir=home_dir)
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
    agent = CodingDiscoverAgent(send=boom, runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    # Must swallow the send error rather than propagate it into the pump.
    agent.handle_frame({"type": "coding_discover_request"})


# ── change-hash throttle ──────────────────────────────────────────────────────


def test_throttle_suppresses_unchanged_polls():
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    clock = FakeClock(100.0)
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                poll_interval=0.01, home_dir=_EMPTY_HOME)
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
                                poll_interval=0.01, home_dir=_EMPTY_HOME)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    # A new claude session appears -> the set changed -> push (no heartbeat).
    fr.stdout = _FOUR_SESSIONS + f"jc-new\t{_real('nnew')}\tclaude\t1717800004\n"
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
                                poll_interval=0.01, home_dir=_EMPTY_HOME)
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
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                home_dir=_EMPTY_HOME)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    # Only last_activity ticks (same names/cwds) -> hash unchanged -> suppressed.
    bumped = _FOUR_SESSIONS.replace("1717800000", "1717999999")
    fr.stdout = bumped
    clock.t = 101.0
    agent._scan_and_push(force=False)
    assert len(sent) == 1


def test_transcript_mtime_change_alone_does_not_repush(tmp_path):
    # A transcript's mtime (= last_activity) ticks on every keypress; since the
    # change-hash excludes last_activity, a pure mtime bump must NOT cause a
    # spurious push (otherwise the throttle is defeated by transcripts).
    home = str(tmp_path)
    clock = FakeClock(100.0)
    cwd = _real("ticky")
    fpath = _write_transcript(home, "p", "ticky", [
        {"type": "summary", "summary": "stable title"},
        _cwd_line(cwd)], mtime=50.0)
    sent = []
    fr = FakeRunner(stdout="")  # no tmux sessions; transcripts only
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                home_dir=home)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    assert any(s["kind"] == "transcript" for s in sent[0]["sessions"])
    # Bump ONLY the mtime (within the heartbeat window) -> hash unchanged.
    os.utime(fpath, (60.0, 60.0))
    clock.t = 101.0
    agent._scan_and_push(force=False)
    assert len(sent) == 1


def test_transcript_live_change_drives_repush(tmp_path):
    # Conversely, when a transcript flips live (a tmux session appears in its
    # cwd), the change-hash DOES change -> a push (live is part of the identity).
    home = str(tmp_path)
    clock = FakeClock(100.0)
    cwd = _real("proj_flip")
    _write_transcript(home, "p", "flip", [
        {"type": "summary", "summary": "t"}, _cwd_line(cwd)],
        mtime=50.0)
    sent = []
    fr = FakeRunner(stdout="")  # initially no live tmux -> transcript live=False
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, clock=clock,
                                home_dir=home)
    agent._scan_and_push(force=True)
    assert len(sent) == 1
    trans0 = [s for s in sent[0]["sessions"] if s["kind"] == "transcript"][0]
    assert trans0["live"] is False
    # A tmux claude session appears in the SAME cwd -> transcript flips live.
    fr.stdout = f"jc-x\t{cwd}\tclaude\t1\n"
    clock.t = 101.0
    agent._scan_and_push(force=False)
    assert len(sent) == 2
    trans1 = [s for s in sent[1]["sessions"] if s["kind"] == "transcript"][0]
    assert trans1["live"] is True


# ── lifecycle (start idempotency / close safety / non-blocking close) ──────────


def test_start_is_idempotent_and_pushes_once_on_start():
    import time as _time
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=sent.append, device_id="dev1", runner=fr,
                                poll_interval=10.0,  # long poll: only the start push
                                home_dir=_EMPTY_HOME)
    try:
        agent.start()
        t1 = agent._thread
        agent.start()  # second call must not spawn a new thread
        assert agent._thread is t1
        # the initial forced push lands shortly after start
        deadline = _time.time() + 2.0
        while not sent and _time.time() < deadline:
            _time.sleep(0.01)
        assert len(sent) == 1
        assert sent[0]["type"] == "coding_discover"
    finally:
        agent.close()


def test_close_is_safe_to_call_twice():
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, poll_interval=10.0,
                                home_dir=_EMPTY_HOME)
    agent.start()
    agent.close()
    assert agent._thread is None
    agent.close()  # double close must not raise / double-join
    assert agent._thread is None


def test_close_returns_promptly_with_blocking_runner():
    # A real tmux that hangs must not wedge disconnect: close() joins with a
    # bounded timeout (the daemon thread is abandoned), so close() returns fast.
    import time as _time
    started = threading.Event()
    release = threading.Event()

    def blocking_runner(argv):
        started.set()
        release.wait(10.0)  # simulate a wedged `tmux list-sessions`
        return 0, "", ""

    agent = CodingDiscoverAgent(send=lambda f: None, runner=blocking_runner,
                                poll_interval=0.01, home_dir=_EMPTY_HOME)
    agent.start()
    assert started.wait(2.0), "poll thread never invoked the runner"
    t0 = _time.time()
    agent.close()  # the runner is still blocked inside the thread
    elapsed = _time.time() - t0
    release.set()  # let the abandoned thread unwind
    assert elapsed < 3.0, f"close() blocked too long: {elapsed:.2f}s"
    assert agent._thread is None


def test_restart_after_close_works():
    # close() sets the stop event; start() must clear it so the agent restarts.
    import time as _time
    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=sent.append, runner=fr, poll_interval=10.0,
                                home_dir=_EMPTY_HOME)
    try:
        agent.start()
        agent.close()
        sent.clear()
        agent.start()  # should spawn a fresh thread and push again
        deadline = _time.time() + 2.0
        while not sent and _time.time() < deadline:
            _time.sleep(0.01)
        assert len(sent) == 1
    finally:
        agent.close()


# ── transcript scan (Claude Code session store) ───────────────────────────────


def _write_transcript(home, project_enc, session_id, lines, *, mtime=None):
    """Write ``<home>/.claude/projects/<project_enc>/<session_id>.jsonl`` from a
    list of dicts (one JSON object per line) and optionally stamp its mtime.

    Returns the file path. ``lines`` entries may also be raw strings, which are
    written verbatim (used to inject malformed/partial JSON lines)."""
    pdir = os.path.join(home, ".claude", "projects", project_enc)
    os.makedirs(pdir, exist_ok=True)
    fpath = os.path.join(pdir, session_id + ".jsonl")
    with open(fpath, "w", encoding="utf-8") as fh:
        for ln in lines:
            if isinstance(ln, str):
                fh.write(ln + "\n")
            else:
                fh.write(json.dumps(ln) + "\n")
    if mtime is not None:
        os.utime(fpath, (mtime, mtime))
    return fpath


def _cwd_line(cwd):
    # A typical event line: carries the real working dir as a top-level "cwd".
    return {"type": "user", "cwd": cwd, "uuid": "u1",
            "message": {"role": "user", "content": "hello there"}}


def test_scan_transcripts_basic(tmp_path):
    home = str(tmp_path)
    now = 1_000_000.0
    cwd_a = _real("proj-a")
    cwd_b = _real("proj-b")
    # Two transcripts in two projects; each has a cwd line + a summary line.
    _write_transcript(home, "proj-a", "11111111-aaaa", [
        {"type": "summary", "summary": "Fix the login bug"},
        _cwd_line(cwd_a),
    ], mtime=now - 100)
    _write_transcript(home, "proj-b", "22222222-bbbb", [
        {"type": "user", "cwd": cwd_b,
         "message": {"role": "user", "content": "do the thing"}},
    ], mtime=now - 200)

    items = scan_transcripts(home, now=now)
    by_id = {it["claude_session_id"]: it for it in items}
    assert set(by_id) == {"11111111-aaaa", "22222222-bbbb"}

    a = by_id["11111111-aaaa"]
    assert a["kind"] == "transcript"
    assert a["cwd"] == cwd_a
    assert a["summary"] == "Fix the login bug"  # explicit summary wins
    assert a["last_activity"] == now - 100      # = file mtime
    assert a["live"] is False
    assert set(a) == {"kind", "claude_session_id", "cwd", "summary",
                      "last_activity", "live"}

    b = by_id["22222222-bbbb"]
    # No summary line -> falls back to the first user message text.
    assert b["summary"] == "do the thing"
    assert b["cwd"] == cwd_b


def test_scan_transcripts_missing_home_returns_empty(tmp_path):
    # No ~/.claude at all -> [] (defensive, never raises).
    assert scan_transcripts(str(tmp_path), now=1000.0) == []
    assert scan_transcripts("/nonexistent/path/xyz", now=1000.0) == []


def test_scan_transcripts_user_content_blocks(tmp_path):
    # content as a list of {type:text,text} blocks -> joined as the summary.
    home = str(tmp_path)
    cwd = _real("blocks")
    _write_transcript(home, "p", "sess-blocks", [
        {"type": "user", "cwd": cwd, "message": {
            "role": "user",
            "content": [
                {"type": "text", "text": "first part"},
                {"type": "image"},  # non-text block ignored
                {"type": "text", "text": "second part"},
            ]}},
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["summary"] == "first part second part"
    assert items[0]["cwd"] == cwd


def test_scan_transcripts_skips_slash_command_boilerplate(tmp_path):
    # Claude Code injects a <command-name>/<local-command-caveat> wrapper as the
    # first "user" message; it must be skipped in favor of the real prose.
    home = str(tmp_path)
    cwd = _real("boil-b")
    _write_transcript(home, "p", "boiler", [
        {"type": "user", "cwd": cwd,
         "message": {"role": "user",
                     "content": "<command-name>resume</command-name>"}},
        {"type": "user",
         "message": {"role": "user", "content": "actually fix the parser"}},
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["summary"] == "actually fix the parser"
    assert items[0]["cwd"] == cwd


def test_scan_transcripts_all_boilerplate_yields_empty_summary(tmp_path):
    # If the only user text is boilerplate and there's no summary line, the
    # summary defaults to "" (cwd still resolves, so the entry is kept).
    home = str(tmp_path)
    cwd = _real("boil-o")
    _write_transcript(home, "p", "onlyboiler", [
        {"type": "user", "cwd": cwd, "message": {
            "role": "user",
            "content": "<local-command-caveat>Caveat: ...</local-command-caveat>"}},
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["summary"] == ""
    assert items[0]["cwd"] == cwd


def test_scan_transcripts_no_cwd_is_skipped(tmp_path):
    # A transcript whose head has no resolvable cwd is skipped entirely.
    home = str(tmp_path)
    _write_transcript(home, "p", "no-cwd", [
        {"type": "summary", "summary": "orphan"},
        {"type": "user", "message": {"role": "user", "content": "hi"}},
    ])
    assert scan_transcripts(home, now=1000.0) == []


def test_scan_transcripts_age_cap(tmp_path):
    home = str(tmp_path)
    now = 2_000_000.0
    day = 86400.0
    cwd_fresh = _real("fresh")
    cwd_stale = _real("stale")
    # Fresh (5 days old) vs stale (40 days old) with max_age_days=30.
    _write_transcript(home, "p", "fresh", [_cwd_line(cwd_fresh)],
                      mtime=now - 5 * day)
    _write_transcript(home, "p", "stale", [_cwd_line(cwd_stale)],
                      mtime=now - 40 * day)
    items = scan_transcripts(home, now=now, max_age_days=30)
    ids = {it["claude_session_id"] for it in items}
    assert ids == {"fresh"}


def test_scan_transcripts_file_cap_logs_skip(tmp_path, caplog):
    import logging as _logging
    home = str(tmp_path)
    now = 3_000_000.0
    # 5 transcripts, distinct mtimes; cap to 2 newest -> 3 skipped + logged.
    for i in range(5):
        _write_transcript(home, "p", f"s{i}", [_cwd_line(_real(f"cap{i}"))],
                          mtime=now - i)  # s0 newest ... s4 oldest
    with caplog.at_level(_logging.INFO, logger="jc_client.coding_discover"):
        items = scan_transcripts(home, now=now, max_files=2)
    ids = {it["claude_session_id"] for it in items}
    assert ids == {"s0", "s1"}  # the two newest
    # The skip is LOGGED (no silent truncation).
    msgs = " ".join(r.getMessage() for r in caplog.records)
    assert "skipped 3" in msgs and "capped at 2" in msgs


def test_scan_transcripts_malformed_lines_robust(tmp_path):
    home = str(tmp_path)
    cwd = _real("messy")
    # Garbage + partial JSON lines mixed with a valid cwd line -> still parsed.
    _write_transcript(home, "p", "messy", [
        "not json at all",
        '{"partial": ',                       # truncated JSON
        "[]",                                  # valid JSON but not a dict
        _cwd_line(cwd),
        '{"type": "summary", "summary": "after the mess"}',
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["cwd"] == cwd
    assert items[0]["summary"] == "after the mess"


def test_scan_transcripts_live_flag(tmp_path):
    home = str(tmp_path)
    cwd_live = _real("live")
    cwd_dead = _real("dead")
    _write_transcript(home, "p", "live-one", [_cwd_line(cwd_live)])
    _write_transcript(home, "p", "dead-one", [_cwd_line(cwd_dead)])
    items = scan_transcripts(home, now=1000.0, live_cwds=[cwd_live])
    by_id = {it["claude_session_id"]: it for it in items}
    assert by_id["live-one"]["live"] is True
    assert by_id["dead-one"]["live"] is False


def test_scan_transcripts_live_flag_trailing_slash_normalized(tmp_path):
    # A live_cwd with a trailing slash (or the transcript cwd with one) must STILL
    # match: the live-match comparison normalizes a trailing slash away so a
    # genuinely-live session isn't wrongly reported live=False on a slash mismatch.
    home = str(tmp_path)
    cwd_proj = _real("slashproj")
    cwd_rev = _real("slashrev")
    _write_transcript(home, "p", "t-slash-live", [_cwd_line(cwd_proj)])
    _write_transcript(home, "p", "t-slash-rev", [_cwd_line(cwd_rev + "/")])
    items = scan_transcripts(
        home, now=1000.0, live_cwds=[cwd_proj + "/", cwd_rev])
    by_id = {it["claude_session_id"]: it for it in items}
    # live_cwd had the slash, transcript cwd didn't -> still live.
    assert by_id["t-slash-live"]["live"] is True
    # transcript cwd had the slash, live_cwd didn't -> still live.
    assert by_id["t-slash-rev"]["live"] is True
    # the EMITTED cwd is left verbatim (server resumes against it).
    assert by_id["t-slash-rev"]["cwd"] == cwd_rev + "/"


def test_scan_transcripts_overlong_line_is_bounded(tmp_path):
    # Regression: a single multi-MB JSONL line (no newline until the very end —
    # e.g. a pasted file or base64 image) must NOT be slurped whole into memory.
    # The bounded head reader drains the overlong line and still recovers the
    # cwd + summary from the cheap lines that follow, peaking well under the giant
    # line's size.
    import tracemalloc
    from jc_client.coding_discover import _extract_cwd_summary

    home = str(tmp_path)
    cwd = _real("giant")
    pdir = os.path.join(home, ".claude", "projects", "p")
    os.makedirs(pdir, exist_ok=True)
    fpath = os.path.join(pdir, "giant.jsonl")
    big = "x" * (8 * 1024 * 1024)  # 8 MiB single line, no embedded newline
    with open(fpath, "w", encoding="utf-8") as fh:
        fh.write(big + "\n")
        fh.write(json.dumps({"cwd": cwd}) + "\n")
        fh.write(json.dumps({"type": "summary", "summary": "after giant"}) + "\n")

    tracemalloc.start()
    cwd_out, summary = _extract_cwd_summary(fpath, head_lines=20)
    _cur, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    assert cwd_out == cwd
    assert summary == "after giant"
    # Bounded: never materialize anywhere near the 8 MiB overlong line.
    assert peak < 4 * 1024 * 1024, f"head read not bounded: peak={peak} bytes"

    # And it surfaces correctly through the full scan, too.
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["cwd"] == cwd
    assert items[0]["summary"] == "after giant"


def test_scan_transcripts_entire_file_one_overlong_line(tmp_path):
    # Worst case: the whole file is one giant line with NO newline at all. The
    # reader must terminate (bounded) and yield nothing resolvable, not hang or
    # OOM. (Whole file = single drained line -> no cwd -> skipped.)
    import tracemalloc
    from jc_client.coding_discover import _extract_cwd_summary

    home = str(tmp_path)
    pdir = os.path.join(home, ".claude", "projects", "p")
    os.makedirs(pdir, exist_ok=True)
    fpath = os.path.join(pdir, "blob.jsonl")
    with open(fpath, "w", encoding="utf-8") as fh:
        fh.write("z" * (6 * 1024 * 1024))  # no newline anywhere

    tracemalloc.start()
    cwd, summary = _extract_cwd_summary(fpath, head_lines=20)
    _cur, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    assert (cwd, summary) == ("", "")
    assert peak < 4 * 1024 * 1024, f"head read not bounded: peak={peak} bytes"
    assert scan_transcripts(home, now=1000.0) == []  # no cwd -> skipped


def test_extract_cwd_summary_trailing_line_without_newline(tmp_path):
    # A tiny single-line transcript with NO trailing newline must still be read
    # (the bounded reader surfaces the final un-terminated line).
    from jc_client.coding_discover import _extract_cwd_summary

    home = str(tmp_path)
    pdir = os.path.join(home, ".claude", "projects", "p")
    os.makedirs(pdir, exist_ok=True)
    fpath = os.path.join(pdir, "oneline.jsonl")
    with open(fpath, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(
            {"cwd": "/w/one", "type": "summary", "summary": "no newline"}))
    cwd, summary = _extract_cwd_summary(fpath, head_lines=20)
    assert cwd == "/w/one"
    assert summary == "no newline"


def test_scan_transcripts_dedup_by_session_id_keeps_newest(tmp_path):
    home = str(tmp_path)
    now = 4_000_000.0
    cwd_old = _real("dold")
    cwd_new = _real("dnew")
    # Same session id in two different project dirs -> newest mtime wins.
    _write_transcript(home, "old-proj", "dup-id", [
        {"type": "summary", "summary": "OLD"}, _cwd_line(cwd_old)],
        mtime=now - 500)
    _write_transcript(home, "new-proj", "dup-id", [
        {"type": "summary", "summary": "NEW"}, _cwd_line(cwd_new)],
        mtime=now - 10)
    items = scan_transcripts(home, now=now)
    assert len(items) == 1
    assert items[0]["summary"] == "NEW"
    assert items[0]["cwd"] == cwd_new
    assert items[0]["last_activity"] == now - 10


# ── combined push (tmux + transcript) ─────────────────────────────────────────


def test_combined_push_includes_tmux_and_transcripts(tmp_path):
    home = str(tmp_path)
    now = 5_000_000.0
    # A live tmux claude session in _CWD_PROJ (matches _FOUR_SESSIONS' jc-abc).
    # A transcript in that SAME cwd -> should come back live=True; plus a
    # transcript in a non-live cwd -> live=False.
    cwd_else = _real("elsewhere")
    _write_transcript(home, "p1", "t-live", [
        {"type": "summary", "summary": "live work"},
        _cwd_line(_CWD_PROJ)],
        mtime=now - 50)
    _write_transcript(home, "p2", "t-past", [
        {"type": "summary", "summary": "past work"},
        _cwd_line(cwd_else)],
        mtime=now - 60)

    sent = []
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=sent.append, device_id="dev1", runner=fr,
                                clock=FakeClock(now), home_dir=home)
    agent.handle_frame({"type": "coding_discover_request"})
    assert len(sent) == 1
    sessions = sent[0]["sessions"]

    kinds = [s["kind"] for s in sessions]
    assert "tmux" in kinds and "transcript" in kinds

    tmux_names = {s["tmux_name"] for s in sessions if s["kind"] == "tmux"}
    assert tmux_names == {"jc-abc", "plain-claude", "jc-launched"}

    transcripts = {s["claude_session_id"]: s
                   for s in sessions if s["kind"] == "transcript"}
    assert set(transcripts) == {"t-live", "t-past"}
    # The transcript whose cwd matches a live tmux session is flagged live.
    assert transcripts["t-live"]["live"] is True
    assert transcripts["t-past"]["live"] is False


def test_combined_scan_survives_unreadable_store(tmp_path, monkeypatch):
    # If the transcript scan blows up, the tmux half must still come through.
    import jc_client.coding_discover as cd

    def boom(*a, **k):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(cd, "scan_transcripts", boom)
    fr = FakeRunner(stdout=_FOUR_SESSIONS)
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr,
                                clock=FakeClock(), home_dir=str(tmp_path))
    sessions = agent.scan()  # must not raise
    assert {s["tmux_name"] for s in sessions if s["kind"] == "tmux"} == {
        "jc-abc", "plain-claude", "jc-launched"}
    assert all(s["kind"] == "tmux" for s in sessions)  # transcripts degraded to []


# ── transcript send (coding_transcript_get -> coding_transcript_data) ──────────


def _write_transcript_at(home, cwd, session_id, content_bytes):
    """Write a transcript at the ENCODED location ``_on_transcript_get`` resolves
    to: ``<home>/.claude/projects/<encode(cwd)>/<session_id>.jsonl``."""
    from jc_client.coding_discover import _encode_project_dir
    pdir = os.path.join(home, ".claude", "projects", _encode_project_dir(cwd))
    os.makedirs(pdir, exist_ok=True)
    fpath = os.path.join(pdir, session_id + ".jsonl")
    with open(fpath, "wb") as fh:
        fh.write(content_bytes)
    return fpath


def _data_frames(sent):
    return [f for f in sent if f.get("type") == "coding_transcript_data"]


def _reassemble(frames):
    """Concat the base64 chunks (in seq order), b64-decode, then gunzip."""
    ordered = sorted(frames, key=lambda f: f["seq"])
    blob = b"".join(base64.b64decode(f["content_b64"]) for f in ordered)
    return gzip.decompress(blob)


def _transcript_agent(sent, home):
    return CodingDiscoverAgent(send=sent.append, device_id="d1",
                               runner=FakeRunner(stdout=""), clock=FakeClock(),
                               home_dir=home)


def test_transcript_get_found_roundtrips(tmp_path):
    home = str(tmp_path)
    cwd = _real("getproj")
    body = (b'{"type":"user","cwd":"x"}\n'
            b'{"type":"summary","summary":"hi"}\n') * 50
    _write_transcript_at(home, cwd, "sess-get-1", body)

    sent = []
    agent = _transcript_agent(sent, home)
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "r1",
                        "claude_session_id": "sess-get-1", "cwd": cwd})

    data = _data_frames(sent)
    assert data, "no data frames sent"
    # No error frame; exactly one eof; contiguous 0-based seqs.
    assert all(f.get("ok") is not False for f in data)
    assert data[-1]["eof"] is True
    assert sum(1 for f in data if f["eof"]) == 1
    assert [f["seq"] for f in data] == list(range(len(data)))
    assert all(f["req_id"] == "r1" and f["claude_session_id"] == "sess-get-1"
               for f in data)
    assert _reassemble(data) == body


def test_transcript_get_multichunk_large_file(tmp_path):
    home = str(tmp_path)
    cwd = _real("getbig")
    # ~900 KiB of incompressible bytes -> gzip stays large -> base64 spans
    # several ≤256 KiB chunks.
    body = os.urandom(900 * 1024)
    _write_transcript_at(home, cwd, "sess-big", body)

    sent = []
    agent = _transcript_agent(sent, home)
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "rb",
                        "claude_session_id": "sess-big", "cwd": cwd})

    data = _data_frames(sent)
    assert len(data) >= 2, "expected a multi-chunk stream"
    # Every non-final chunk is a full 256 KiB of base64 and not eof.
    for f in data[:-1]:
        assert f["eof"] is False
        assert len(f["content_b64"]) == 256 * 1024
    assert data[-1]["eof"] is True
    assert _reassemble(data) == body


def test_transcript_get_empty_file_single_eof(tmp_path):
    home = str(tmp_path)
    cwd = _real("getempty")
    _write_transcript_at(home, cwd, "sess-empty", b"")

    sent = []
    agent = _transcript_agent(sent, home)
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "re",
                        "claude_session_id": "sess-empty", "cwd": cwd})

    data = _data_frames(sent)
    # Exactly one chunk, eof, seq 0; it gunzips back to empty bytes.
    assert len(data) == 1
    assert data[0]["eof"] is True
    assert data[0]["seq"] == 0
    assert data[0].get("ok") is not False
    assert _reassemble(data) == b""


def test_transcript_get_fallback_glob(tmp_path):
    # The file is stored under a project dir that does NOT match encode(cwd)
    # (realpath/symlink quirk); the glob fallback must still find it by id.
    home = str(tmp_path)
    pdir = os.path.join(home, ".claude", "projects", "some-unrelated-enc")
    os.makedirs(pdir)
    body = b'{"hello":"world"}\n'
    with open(os.path.join(pdir, "sess-glob.jsonl"), "wb") as fh:
        fh.write(body)

    sent = []
    agent = _transcript_agent(sent, home)
    # cwd encodes to a dir that doesn't exist -> encoded lookup misses -> glob.
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "rg",
                        "claude_session_id": "sess-glob",
                        "cwd": "/nonmatching/path/xyz"})

    data = _data_frames(sent)
    assert data and data[-1]["eof"] is True
    assert all(f.get("ok") is not False for f in data)
    assert _reassemble(data) == body


def test_transcript_get_honors_claude_config_dir(tmp_path, monkeypatch):
    # With CLAUDE_CONFIG_DIR set, the transcript is read from <that>/projects,
    # NOT <home>/.claude/projects.
    from jc_client.coding_discover import _encode_project_dir
    cfg = tmp_path / "cfg"
    cwd = _real("cfgproj")
    pdir = cfg / "projects" / _encode_project_dir(cwd)
    pdir.mkdir(parents=True)
    body = b'{"x":1}\n'
    (pdir / "sess-cfg.jsonl").write_bytes(body)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(cfg))

    sent = []
    # home_dir points elsewhere (no transcript there) -> must use CLAUDE_CONFIG_DIR.
    agent = _transcript_agent(sent, str(tmp_path / "otherhome"))
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "rc",
                        "claude_session_id": "sess-cfg", "cwd": cwd})

    data = _data_frames(sent)
    assert data and data[-1]["eof"] is True
    assert _reassemble(data) == body


def test_transcript_get_missing_session_returns_error(tmp_path):
    home = str(tmp_path)
    sent = []
    agent = _transcript_agent(sent, home)
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "rX",
                        "claude_session_id": "does-not-exist",
                        "cwd": _real("nope")})
    data = _data_frames(sent)
    assert len(data) == 1
    assert data[0]["ok"] is False
    assert data[0]["req_id"] == "rX"
    assert data[0].get("error")
    # An error frame carries no content/eof.
    assert "content_b64" not in data[0]


def test_transcript_get_oversize_returns_error(tmp_path, monkeypatch):
    import jc_client.coding_discover as cd
    monkeypatch.setattr(cd, "_TRANSCRIPT_GET_MAX_BYTES", 8)
    home = str(tmp_path)
    cwd = _real("getoversz")
    _write_transcript_at(home, cwd, "sess-over", b"x" * 100)  # > 8 byte cap

    sent = []
    agent = _transcript_agent(sent, home)
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "ro",
                        "claude_session_id": "sess-over", "cwd": cwd})
    data = _data_frames(sent)
    assert len(data) == 1
    assert data[0]["ok"] is False
    assert "too large" in data[0]["error"]


def test_transcript_get_bad_session_id_returns_error(tmp_path):
    # A path-traversal / empty session id is rejected before touching the FS.
    home = str(tmp_path)
    for bad in ("", "../escape", "a/b", ".."):
        sent = []
        agent = _transcript_agent(sent, home)
        agent.handle_frame({"type": "coding_transcript_get", "req_id": "rbad",
                            "claude_session_id": bad, "cwd": _real("any")})
        data = _data_frames(sent)
        assert len(data) == 1 and data[0]["ok"] is False, bad


def test_transcript_get_send_failure_does_not_raise(tmp_path):
    # A send failure mid-stream must be swallowed (never bubble into the pump).
    home = str(tmp_path)
    cwd = _real("getsendfail")
    _write_transcript_at(home, cwd, "sess-sf", b"data\n")

    def boom(_f):
        raise RuntimeError("ws closed")

    agent = CodingDiscoverAgent(send=boom, runner=FakeRunner(stdout=""),
                                clock=FakeClock(), home_dir=home)
    agent.handle_frame({"type": "coding_transcript_get", "req_id": "rsf",
                        "claude_session_id": "sess-sf", "cwd": cwd})


# ── transcript RECEIVE (coding_transcript_put) ───────────────────────────────

def _put_frames(req_id, csid, cwd, raw, *, chunk_b64=None):
    from jc_client.coding_discover import _TRANSCRIPT_CHUNK_B64
    chunk = chunk_b64 or _TRANSCRIPT_CHUNK_B64
    payload = base64.b64encode(gzip.compress(raw)).decode("ascii")
    frames, seq, pos = [], 0, 0
    while True:
        piece = payload[pos:pos + chunk]
        pos += chunk
        eof = pos >= len(payload)
        frames.append({"type": "coding_transcript_put", "req_id": req_id,
                       "claude_session_id": csid, "cwd": cwd, "seq": seq,
                       "eof": eof, "content_b64": piece})
        seq += 1
        if eof:
            break
    return frames


def _read_put(home, cwd, csid):
    from jc_client.coding_discover import (_claude_projects_dir,
                                           _encode_project_dir)
    path = os.path.join(_claude_projects_dir(home),
                        _encode_project_dir(cwd), csid + ".jsonl")
    with open(path, "rb") as fh:
        return fh.read()


def test_transcript_put_writes_file(tmp_path):
    home = str(tmp_path)
    cwd = _real("putproj")
    body = (b'{"type":"user"}\n{"type":"assistant"}\n') * 30
    agent = _transcript_agent([], home)
    for fr in _put_frames("p1", "sess-put-1", cwd, body):
        agent.handle_frame(fr)
    assert _read_put(home, cwd, "sess-put-1") == body


def test_transcript_put_multichunk_reassembles(tmp_path):
    home = str(tmp_path)
    cwd = _real("putbig")
    body = (b'{"k":"v","pad":"' + b'x' * 500 + b'"}\n') * 400
    agent = _transcript_agent([], home)
    frames = _put_frames("pb", "sess-big", cwd, body, chunk_b64=64)
    assert len(frames) > 1
    for fr in frames:
        agent.handle_frame(fr)
    assert _read_put(home, cwd, "sess-big") == body


def test_transcript_put_rejects_bad_session_id(tmp_path):
    home = str(tmp_path)
    cwd = _real("putbad")
    agent = _transcript_agent([], home)
    for fr in _put_frames("pbad", "../evil", cwd, b"x\n"):
        agent.handle_frame(fr)
    hits = []
    for root, _dirs, files in os.walk(home):
        hits += [f for f in files if f.endswith(".jsonl")]
    assert hits == []


def test_transcript_put_rejects_decompression_bomb(tmp_path, monkeypatch):
    import jc_client.coding_discover as cd
    monkeypatch.setattr(cd, "_TRANSCRIPT_PUT_MAX_RAW_BYTES", 1024)
    home = str(tmp_path)
    cwd = _real("putbomb")
    bomb = b"A" * (50 * 1024)
    agent = _transcript_agent([], home)
    for fr in _put_frames("pbomb", "sess-bomb", cwd, bomb):
        agent.handle_frame(fr)
    from jc_client.coding_discover import (_claude_projects_dir,
                                           _encode_project_dir)
    path = os.path.join(_claude_projects_dir(home),
                        _encode_project_dir(cwd), "sess-bomb.jsonl")
    assert not os.path.exists(path)


# ── tmux row enrichment with claude_session_id (offline-resume support) ──────

def test_enrich_tmux_with_csids_newest_wins():
    from jc_client.coding_discover import _enrich_tmux_with_csids
    tmux = [{"kind": "tmux", "tmux_name": "jc-a", "cwd": "/Users/me/proj"},
            {"kind": "tmux", "tmux_name": "jc-b", "cwd": "/Users/me/other"}]
    transcripts = [
        {"kind": "transcript", "claude_session_id": "old", "cwd": "/Users/me/proj",
         "last_activity": 100.0},
        {"kind": "transcript", "claude_session_id": "new", "cwd": "/Users/me/proj",
         "last_activity": 200.0},  # newest in this cwd -> wins
    ]
    _enrich_tmux_with_csids(tmux, transcripts)
    assert tmux[0]["claude_session_id"] == "new"
    assert "claude_session_id" not in tmux[1]  # no transcript for its cwd


def test_enrich_tmux_skips_ambiguous_cwd():
    # SEVERAL live tmux sessions in one cwd: the newest transcript belongs to
    # exactly one of them, so stamping it on all would let the server's hook
    # matcher (csid fallback) write one sibling's event onto another's row.
    from jc_client.coding_discover import _enrich_tmux_with_csids
    tmux = [{"kind": "tmux", "tmux_name": "15", "cwd": "/Users/me/proj"},
            {"kind": "tmux", "tmux_name": "11", "cwd": "/Users/me/proj"},
            {"kind": "tmux", "tmux_name": "2", "cwd": "/Users/me/other"}]
    transcripts = [
        {"kind": "transcript", "claude_session_id": "p1", "cwd": "/Users/me/proj",
         "last_activity": 200.0},
        {"kind": "transcript", "claude_session_id": "o1", "cwd": "/Users/me/other",
         "last_activity": 100.0},
    ]
    _enrich_tmux_with_csids(tmux, transcripts)
    assert "claude_session_id" not in tmux[0]   # ambiguous — left bare
    assert "claude_session_id" not in tmux[1]
    assert tmux[2]["claude_session_id"] == "o1"  # unambiguous — still stamped


def test_tmux_capture_argv_uses_exact_match_target():
    # Bare numeric names ("2", "15") go through tmux's fuzzy target resolution
    # (window index / name prefix) and can capture a DIFFERENT session's pane —
    # the `=name:` syntax forces an exact session match.
    from jc_client.coding_discover import tmux_capture_argv
    assert tmux_capture_argv("2") == [
        "tmux", "capture-pane", "-p", "-t", "=2:", "-S", "-80"]


def test_enrich_tmux_does_not_overwrite_existing_csid():
    from jc_client.coding_discover import _enrich_tmux_with_csids
    tmux = [{"kind": "tmux", "tmux_name": "jc-a", "cwd": "/p",
             "claude_session_id": "already"}]
    _enrich_tmux_with_csids(
        tmux, [{"claude_session_id": "other", "cwd": "/p", "last_activity": 9.0}])
    assert tmux[0]["claude_session_id"] == "already"


# ── live activity_state classification ────────────────────────────────────────


def test_classify_pane_basic():
    from jc_client.coding_discover import classify_pane
    assert classify_pane("✻ Running… (esc to interrupt)") == "working"
    assert classify_pane("Do you want to proceed?\n❯ 1. Yes") == "waiting"
    assert classify_pane("> ready") == "idle"
    assert classify_pane("") == "idle"


def test_scan_classifies_activity_state():
    proj = _real("act")
    listing = f"jc-act\t{proj}\tclaude\t1717800000\n"
    panes = {"jc-act": "✻ Running… (esc to interrupt)"}

    def runner(argv):
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, listing, ""
        if argv[:2] == ["tmux", "capture-pane"]:
            return 0, panes.get(argv[4].strip("=:"), ""), ""  # -t "=name:" exact target
        return 1, "", ""

    agent = CodingDiscoverAgent(send=lambda f: None, device_id="dev1",
                                runner=runner, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    rows = [s for s in agent.scan() if s["kind"] == "tmux"]
    assert len(rows) == 1
    assert rows[0]["activity_state"] == "working"


def test_scan_activity_state_none_on_capture_failure():
    proj = _real("act2")
    listing = f"jc-act2\t{proj}\tclaude\t1717800000\n"

    def runner(argv):
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, listing, ""
        return 1, "", "no pane"  # capture-pane fails -> None, never raises

    agent = CodingDiscoverAgent(send=lambda f: None, runner=runner,
                                clock=FakeClock(), home_dir=_EMPTY_HOME)
    rows = [s for s in agent.scan() if s["kind"] == "tmux"]
    assert rows and rows[0]["activity_state"] is None


def test_scan_blank_capture_is_unknown_not_idle():
    # A capture that SUCCEEDS (rc 0) but returns an empty / whitespace pane — a
    # mid-teardown repaint racing the capture, common when a SIBLING session is
    # dying — must be reported as activity_state=None ("unknown"), NOT "idle".
    # Otherwise the server clobbers a live "working" with a guessed idle, which is
    # the cross-session status-bleed bug.
    proj = _real("blank")
    listing = f"jc-blank\t{proj}\tclaude\t1717800000\n"

    def runner(argv):
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, listing, ""
        if argv[:2] == ["tmux", "capture-pane"]:
            return 0, "   \n  \n", ""   # rc 0 but blank — must NOT become idle
        return 1, "", ""

    agent = CodingDiscoverAgent(send=lambda f: None, runner=runner,
                                clock=FakeClock(), home_dir=_EMPTY_HOME)
    rows = [s for s in agent.scan() if s["kind"] == "tmux"]
    assert rows and rows[0]["activity_state"] is None


def test_scan_keeps_working_session_via_pane_content():
    # While Claude runs a tool, pane_current_command is the TOOL (not 'claude'),
    # so the command filter misses it — the pane content must still keep it.
    proj = _real("work-tool")
    listing = f"sess-x\t{proj}\tnode\t1717800000\n"   # command 'node', not jc-/claude
    panes = {"sess-x": "● editing files…\n✻ Running… (esc to interrupt)"}

    def runner(argv):
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, listing, ""
        if argv[:2] == ["tmux", "capture-pane"]:
            return 0, panes.get(argv[4].strip("=:"), ""), ""
        return 1, "", ""

    agent = CodingDiscoverAgent(send=lambda f: None, runner=runner,
                                clock=FakeClock(), home_dir=_EMPTY_HOME)
    rows = [s for s in agent.scan() if s["kind"] == "tmux"]
    assert [r["tmux_name"] for r in rows] == ["sess-x"]
    assert rows[0]["activity_state"] == "working"


def test_known_claude_session_kept_when_pane_loses_markers():
    # Once known to be Claude, a later scan whose pane shows only tool output
    # (no Claude markers) must STILL keep it — don't flicker out mid-tool.
    proj = _real("known-keep")
    listing = f"sess-y\t{proj}\tnode\t1717800000\n"
    state = {"pane": "? for shortcuts\n> "}  # 1st scan: idle Claude footer

    def runner(argv):
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, listing, ""
        if argv[:2] == ["tmux", "capture-pane"]:
            return 0, state["pane"], ""
        return 1, "", ""

    agent = CodingDiscoverAgent(send=lambda f: None, runner=runner,
                                clock=FakeClock(), home_dir=_EMPTY_HOME)
    first = [s["tmux_name"] for s in agent.scan() if s["kind"] == "tmux"]
    assert first == ["sess-y"]  # recognized via pane content
    state["pane"] = "npm test\nlots of output...\nPASS"  # Claude UI scrolled away
    second = [s["tmux_name"] for s in agent.scan() if s["kind"] == "tmux"]
    assert second == ["sess-y"]  # still kept via the known-claude set


def test_is_claude_pane_recognizes_custom_statusline():
    from jc_client.coding_discover import is_claude_pane
    # The user's pane: a custom statusline + the bypass-permissions footer — must
    # be detected even though pane_current_command isn't 'claude'.
    pane = ("Opus 4.8 (1M context) | effort:xhigh | 5h:[..]19% | ctx:3%\n"
            "bypass permissions on (shift+tab to cycle) · for agents")
    assert is_claude_pane(pane) is True
    assert is_claude_pane("pranav@mac ~ % ls\nfile1 file2") is False


def test_classify_working_spinner_custom_fork():
    from jc_client.coding_discover import classify_pane
    pane = "✽ Precipitating… (35s · ↑ 2.4k tokens · thinking with xhigh effort)\n❯ "
    assert classify_pane(pane) == "working"
