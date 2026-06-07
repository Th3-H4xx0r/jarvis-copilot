"""Unit tests for the desktop coding-session discovery agent.

Covers the PURE ``parse_tmux_list`` (well-formed / blank lines / missing fields),
the claude/jc- filter, the on-demand ``coding_discover_request`` push, the
change-hash throttle, and the PURE ``scan_transcripts`` (Claude Code session
store) + its integration into the combined push. A FakeRunner + fake clock keep
tmux and the wall clock out; an injected ``home_dir`` keeps the real ``~/.claude``
out (the tmux-only tests point at an EMPTY tmp home so they stay tmux-only).
"""
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
                                runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
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
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    assert agent.scan() == []


def test_scan_keeps_claude_launched_by_absolute_path():
    # tmux can report pane_current_command as a full path when claude is started
    # by absolute path; the basename is still "claude" -> must be kept.
    out = (
        "abs\t/Users/me/a\t/usr/local/bin/claude\t1\n"   # path to claude -> keep
        "node-only\t/Users/me/n\tnode\t2\n"               # bare node -> drop
        "zsh-only\t/Users/me/z\t/bin/zsh\t3\n"            # path to zsh -> drop
    )
    fr = FakeRunner(stdout=out)
    agent = CodingDiscoverAgent(send=lambda f: None, runner=fr, clock=FakeClock(),
                                home_dir=_EMPTY_HOME)
    names = {s["tmux_name"] for s in agent.scan()}
    assert names == {"abs"}


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
    fpath = _write_transcript(home, "p", "ticky", [
        {"type": "summary", "summary": "stable title"},
        _cwd_line("/w/ticky")], mtime=50.0)
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
    _write_transcript(home, "p", "flip", [
        {"type": "summary", "summary": "t"}, _cwd_line("/Users/me/proj")],
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
    fr.stdout = "jc-x\t/Users/me/proj\tclaude\t1\n"
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
    # Two transcripts in two projects; each has a cwd line + a summary line.
    _write_transcript(home, "proj-a", "11111111-aaaa", [
        {"type": "summary", "summary": "Fix the login bug"},
        _cwd_line("/Users/me/proj-a"),
    ], mtime=now - 100)
    _write_transcript(home, "proj-b", "22222222-bbbb", [
        {"type": "user", "cwd": "/Users/me/proj-b",
         "message": {"role": "user", "content": "do the thing"}},
    ], mtime=now - 200)

    items = scan_transcripts(home, now=now)
    by_id = {it["claude_session_id"]: it for it in items}
    assert set(by_id) == {"11111111-aaaa", "22222222-bbbb"}

    a = by_id["11111111-aaaa"]
    assert a["kind"] == "transcript"
    assert a["cwd"] == "/Users/me/proj-a"
    assert a["summary"] == "Fix the login bug"  # explicit summary wins
    assert a["last_activity"] == now - 100      # = file mtime
    assert a["live"] is False
    assert set(a) == {"kind", "claude_session_id", "cwd", "summary",
                      "last_activity", "live"}

    b = by_id["22222222-bbbb"]
    # No summary line -> falls back to the first user message text.
    assert b["summary"] == "do the thing"
    assert b["cwd"] == "/Users/me/proj-b"


def test_scan_transcripts_missing_home_returns_empty(tmp_path):
    # No ~/.claude at all -> [] (defensive, never raises).
    assert scan_transcripts(str(tmp_path), now=1000.0) == []
    assert scan_transcripts("/nonexistent/path/xyz", now=1000.0) == []


def test_scan_transcripts_user_content_blocks(tmp_path):
    # content as a list of {type:text,text} blocks -> joined as the summary.
    home = str(tmp_path)
    _write_transcript(home, "p", "sess-blocks", [
        {"type": "user", "cwd": "/w/blocks", "message": {
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
    assert items[0]["cwd"] == "/w/blocks"


def test_scan_transcripts_skips_slash_command_boilerplate(tmp_path):
    # Claude Code injects a <command-name>/<local-command-caveat> wrapper as the
    # first "user" message; it must be skipped in favor of the real prose.
    home = str(tmp_path)
    _write_transcript(home, "p", "boiler", [
        {"type": "user", "cwd": "/w/b",
         "message": {"role": "user",
                     "content": "<command-name>resume</command-name>"}},
        {"type": "user",
         "message": {"role": "user", "content": "actually fix the parser"}},
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["summary"] == "actually fix the parser"
    assert items[0]["cwd"] == "/w/b"


def test_scan_transcripts_all_boilerplate_yields_empty_summary(tmp_path):
    # If the only user text is boilerplate and there's no summary line, the
    # summary defaults to "" (cwd still resolves, so the entry is kept).
    home = str(tmp_path)
    _write_transcript(home, "p", "onlyboiler", [
        {"type": "user", "cwd": "/w/o", "message": {
            "role": "user",
            "content": "<local-command-caveat>Caveat: ...</local-command-caveat>"}},
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["summary"] == ""
    assert items[0]["cwd"] == "/w/o"


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
    # Fresh (5 days old) vs stale (40 days old) with max_age_days=30.
    _write_transcript(home, "p", "fresh", [_cwd_line("/w/fresh")],
                      mtime=now - 5 * day)
    _write_transcript(home, "p", "stale", [_cwd_line("/w/stale")],
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
        _write_transcript(home, "p", f"s{i}", [_cwd_line(f"/w/{i}")],
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
    # Garbage + partial JSON lines mixed with a valid cwd line -> still parsed.
    _write_transcript(home, "p", "messy", [
        "not json at all",
        '{"partial": ',                       # truncated JSON
        "[]",                                  # valid JSON but not a dict
        _cwd_line("/w/messy"),
        '{"type": "summary", "summary": "after the mess"}',
    ])
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["cwd"] == "/w/messy"
    assert items[0]["summary"] == "after the mess"


def test_scan_transcripts_live_flag(tmp_path):
    home = str(tmp_path)
    _write_transcript(home, "p", "live-one", [_cwd_line("/w/live")])
    _write_transcript(home, "p", "dead-one", [_cwd_line("/w/dead")])
    items = scan_transcripts(home, now=1000.0, live_cwds=["/w/live"])
    by_id = {it["claude_session_id"]: it for it in items}
    assert by_id["live-one"]["live"] is True
    assert by_id["dead-one"]["live"] is False


def test_scan_transcripts_live_flag_trailing_slash_normalized(tmp_path):
    # A live_cwd with a trailing slash (or the transcript cwd with one) must STILL
    # match: the live-match comparison normalizes a trailing slash away so a
    # genuinely-live session isn't wrongly reported live=False on a slash mismatch.
    home = str(tmp_path)
    _write_transcript(home, "p", "t-slash-live", [_cwd_line("/w/proj")])
    _write_transcript(home, "p", "t-slash-rev", [_cwd_line("/w/rev/")])
    items = scan_transcripts(
        home, now=1000.0, live_cwds=["/w/proj/", "/w/rev"])
    by_id = {it["claude_session_id"]: it for it in items}
    # live_cwd had the slash, transcript cwd didn't -> still live.
    assert by_id["t-slash-live"]["live"] is True
    # transcript cwd had the slash, live_cwd didn't -> still live.
    assert by_id["t-slash-rev"]["live"] is True
    # the EMITTED cwd is left verbatim (server resumes against it).
    assert by_id["t-slash-rev"]["cwd"] == "/w/rev/"


def test_scan_transcripts_overlong_line_is_bounded(tmp_path):
    # Regression: a single multi-MB JSONL line (no newline until the very end —
    # e.g. a pasted file or base64 image) must NOT be slurped whole into memory.
    # The bounded head reader drains the overlong line and still recovers the
    # cwd + summary from the cheap lines that follow, peaking well under the giant
    # line's size.
    import tracemalloc
    from jc_client.coding_discover import _extract_cwd_summary

    home = str(tmp_path)
    pdir = os.path.join(home, ".claude", "projects", "p")
    os.makedirs(pdir, exist_ok=True)
    fpath = os.path.join(pdir, "giant.jsonl")
    big = "x" * (8 * 1024 * 1024)  # 8 MiB single line, no embedded newline
    with open(fpath, "w", encoding="utf-8") as fh:
        fh.write(big + "\n")
        fh.write(json.dumps({"cwd": "/w/giant"}) + "\n")
        fh.write(json.dumps({"type": "summary", "summary": "after giant"}) + "\n")

    tracemalloc.start()
    cwd, summary = _extract_cwd_summary(fpath, head_lines=20)
    _cur, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    assert cwd == "/w/giant"
    assert summary == "after giant"
    # Bounded: never materialize anywhere near the 8 MiB overlong line.
    assert peak < 4 * 1024 * 1024, f"head read not bounded: peak={peak} bytes"

    # And it surfaces correctly through the full scan, too.
    items = scan_transcripts(home, now=1000.0)
    assert len(items) == 1
    assert items[0]["cwd"] == "/w/giant"
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
    # Same session id in two different project dirs -> newest mtime wins.
    _write_transcript(home, "old-proj", "dup-id", [
        {"type": "summary", "summary": "OLD"}, _cwd_line("/w/old")],
        mtime=now - 500)
    _write_transcript(home, "new-proj", "dup-id", [
        {"type": "summary", "summary": "NEW"}, _cwd_line("/w/new")],
        mtime=now - 10)
    items = scan_transcripts(home, now=now)
    assert len(items) == 1
    assert items[0]["summary"] == "NEW"
    assert items[0]["cwd"] == "/w/new"
    assert items[0]["last_activity"] == now - 10


# ── combined push (tmux + transcript) ─────────────────────────────────────────


def test_combined_push_includes_tmux_and_transcripts(tmp_path):
    home = str(tmp_path)
    now = 5_000_000.0
    # A live tmux claude session in /Users/me/proj (matches _FOUR_SESSIONS).
    # A transcript in that SAME cwd -> should come back live=True; plus a
    # transcript in a non-live cwd -> live=False.
    _write_transcript(home, "p1", "t-live", [
        {"type": "summary", "summary": "live work"},
        _cwd_line("/Users/me/proj")],
        mtime=now - 50)
    _write_transcript(home, "p2", "t-past", [
        {"type": "summary", "summary": "past work"},
        _cwd_line("/Users/me/elsewhere")],
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


def test_coding_resume_launches_tmux_and_rescans():
    """An inbound coding_resume runs `tmux new-session … claude --resume <id>`
    in the session's cwd, then forces a re-scan so the new live session reports."""
    from jc_client.coding_discover import (
        CodingDiscoverAgent, tmux_resume_argv)
    sent = []
    calls = []

    def runner(argv):
        calls.append(argv)
        # tmux list-sessions returns the just-resumed session as live claude
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, "jc-resumed\t/work/p\tclaude\t100\n", ""
        return 0, "", ""

    agent = CodingDiscoverAgent(send=lambda f: sent.append(f), device_id="d1",
                                runner=runner, clock=lambda: 1.0,
                                home_dir="/nonexistent-home")
    agent.handle_frame({"type": "coding_resume", "tmux_name": "jc-resumed",
                        "cwd": "/work/p", "claude_session_id": "abc-123"})
    # the resume launch argv was issued, with the exact pure-exec shape
    assert tmux_resume_argv("jc-resumed", "/work/p", "abc-123") in calls
    # and a discover push followed (the new live session is reported)
    pushes = [f for f in sent if f.get("type") == "coding_discover"]
    assert pushes and any(s.get("tmux_name") == "jc-resumed"
                          for s in pushes[-1]["sessions"])


def test_coding_resume_ignores_incomplete_frame():
    from jc_client.coding_discover import CodingDiscoverAgent
    calls = []
    agent = CodingDiscoverAgent(send=lambda f: None, device_id="d1",
                                runner=lambda a: (calls.append(a), (0, "", ""))[1],
                                clock=lambda: 1.0, home_dir="/nonexistent-home")
    agent.handle_frame({"type": "coding_resume", "tmux_name": "jc-x"})  # no cwd/id
    assert not any(c[:2] == ["tmux", "new-session"] for c in calls)


def test_coding_resume_duplicate_session_does_not_raise():
    # `tmux new-session -s <name>` fails (rc=1, "duplicate session") when the name
    # already exists. The resume handler must log + NOT crash, and still rescan
    # (the existing session is reported, so the user can attach).
    from jc_client.coding_discover import CodingDiscoverAgent
    calls = []

    def runner(argv):
        calls.append(argv)
        if argv[:2] == ["tmux", "new-session"]:
            return 1, "", "duplicate session: jc-dup"  # already exists
        if argv[:2] == ["tmux", "list-sessions"]:
            return 0, "jc-dup\t/work/p\tclaude\t100\n", ""
        return 0, "", ""

    sent = []
    agent = CodingDiscoverAgent(send=sent.append, device_id="d1", runner=runner,
                                clock=lambda: 1.0, home_dir="/nonexistent-home")
    # Must not raise into the pump despite the non-zero launch rc.
    agent.handle_frame({"type": "coding_resume", "tmux_name": "jc-dup",
                        "cwd": "/work/p", "claude_session_id": "abc-123"})
    # A rescan still happened and reports the (already-live) session.
    pushes = [f for f in sent if f.get("type") == "coding_discover"]
    assert pushes and any(s.get("tmux_name") == "jc-dup"
                          for s in pushes[-1]["sessions"])


def test_coding_resume_runner_exception_does_not_raise():
    # If the runner itself throws (e.g. tmux binary explodes), the resume handler
    # must swallow it (no bubble into the WS pump) and NOT push a phantom session.
    from jc_client.coding_discover import CodingDiscoverAgent

    def runner(argv):
        raise RuntimeError("tmux exploded")

    sent = []
    agent = CodingDiscoverAgent(send=sent.append, device_id="d1", runner=runner,
                                clock=lambda: 1.0, home_dir="/nonexistent-home")
    agent.handle_frame({"type": "coding_resume", "tmux_name": "jc-x",
                        "cwd": "/work/p", "claude_session_id": "abc-123"})
    # Launch failed before the rescan -> no push (and definitely no exception).
    assert not [f for f in sent if f.get("type") == "coding_discover"]
