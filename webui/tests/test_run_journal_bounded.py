"""Run journals stay cheap to read and bounded on disk.

A `done` line carries a whole session, so journals used to be read whole for a
status check, grow by the chat's size every turn, and never be deleted.
"""
import json
import os
import time

import api.run_journal as rj
from api.run_journal import (
    append_run_event,
    bounded_journal_payload,
    find_run_summary,
    latest_run_summary,
    prune_run_journals,
    read_run_events,
    start_retention_janitor,
)


def _journal_path(tmp_path, sid="session_1", rid="run_1"):
    return tmp_path / "_run_journal" / sid / f"{rid}.jsonl"


def _raw_event_line(seq, event, payload_json, *, terminal=False, terminal_state=None, rid="run_1"):
    """A line in append_run_event's layout with a caller-supplied payload text."""
    head = {
        "version": 1, "event_id": f"{rid}:{seq}", "seq": seq, "run_id": rid,
        "session_id": "session_1", "event": event, "type": event, "created_at": 1.0,
        "terminal": terminal, "terminal_state": terminal_state,
    }
    return json.dumps(head, separators=(",", ":"))[:-1] + ',"payload":' + payload_json + "}\n"


def test_summary_reads_long_lines_without_decoding_their_payload(tmp_path):
    path = _journal_path(tmp_path)
    path.parent.mkdir(parents=True)
    # A payload that is not valid JSON proves it is never decoded: decoding it
    # would turn the line malformed and drop the terminal event from the summary.
    with path.open("w", encoding="utf-8") as fh:
        fh.write(_raw_event_line(1, "token", '{"text":"hi"}'))
        fh.write(_raw_event_line(2, "done", "{" + "x" * 50000, terminal=True, terminal_state="completed"))
        fh.write(_raw_event_line(3, "metering", '{"tps":1}'))

    summary = find_run_summary("run_1", session_dir=tmp_path)

    assert summary["event_count"] == 3
    assert summary["last_seq"] == 3
    assert summary["terminal"] is True
    assert summary["terminal_state"] == "completed"
    assert summary["last_event"] == "metering"
    assert latest_run_summary("session_1", "run_1", session_dir=tmp_path)["terminal_state"] == "completed"


def test_read_after_cursor_skips_decoding_old_long_lines(tmp_path):
    path = _journal_path(tmp_path)
    path.parent.mkdir(parents=True)
    with path.open("w", encoding="utf-8") as fh:
        fh.write(_raw_event_line(1, "done", "{" + "x" * 50000, terminal=True, terminal_state="completed"))
        fh.write(_raw_event_line(2, "stream_end", "{}", terminal=True, terminal_state="completed"))

    journal = read_run_events("session_1", "run_1", after_seq=1, session_dir=tmp_path)

    assert [e["event"] for e in journal["events"]] == ["stream_end"]
    assert journal["malformed"] == []


def test_long_lines_round_trip_and_match_a_plain_parse(tmp_path, monkeypatch):
    # Tiny chunks and heads push every line across chunk and head boundaries.
    monkeypatch.setattr(rj, "_SCAN_CHUNK_BYTES", 7)
    monkeypatch.setattr(rj, "_HEAD_BYTES", 40)
    monkeypatch.setenv("HERMES_WEBUI_RUN_JOURNAL_DONE_MESSAGES", "0")
    big = {"session": {"session_id": "session_1", "messages": [{"role": "user", "content": "é " * 500}]}}
    for i, (name, payload) in enumerate([("token", {"text": "a"}), ("done", big), ("stream_end", {})], start=1):
        append_run_event("session_1", "run_1", name, payload, session_dir=tmp_path, seq=i)
    path = _journal_path(tmp_path)
    with path.open("a", encoding="utf-8") as fh:
        fh.write("\n{not json}\n")

    journal = read_run_events("session_1", "run_1", session_dir=tmp_path)

    expected = [json.loads(line) for line in path.read_text(encoding="utf-8").split("\n")
                if line.strip() and line.startswith('{"')]
    assert journal["events"] == expected
    assert journal["events"][1]["payload"] == big
    assert [m["line"] for m in journal["malformed"]] == [5]
    assert rj._next_seq(path) == 4


def test_done_is_journaled_as_a_tail_window_and_the_live_payload_is_untouched(tmp_path):
    messages = [
        {"role": "user" if i % 2 == 0 else "assistant", "content": f"m{i}"} for i in range(100)
    ]
    live = {"session": {"session_id": "session_1", "messages": messages, "tool_calls": [{"name": "x"}]},
            "usage": {"input_tokens": 5}}

    event = append_run_event("session_1", "run_1", "done", live, session_dir=tmp_path)

    stored = read_run_events("session_1", "run_1", session_dir=tmp_path)["events"][0]["payload"]
    session = stored["session"]
    assert [m["content"] for m in session["messages"]] == [f"m{i}" for i in range(70, 100)]
    assert session["_messages_truncated"] is True
    assert session["_messages_offset"] == 70
    assert session["tool_calls"] == [{"name": "x"}]  # messages carry no tool metadata
    assert stored["usage"] == {"input_tokens": 5}
    assert event["terminal_state"] == "completed"
    assert len(live["session"]["messages"]) == 100
    assert "_messages_truncated" not in live["session"]


def test_done_tail_drops_session_tool_calls_when_messages_carry_them():
    messages = [{"role": "assistant", "content": "", "tool_calls": [{"id": f"c{i}"}]} for i in range(40)]
    payload = {"session": {"messages": messages, "tool_calls": [{"id": "old"}] * 40}}

    bounded = bounded_journal_payload("done", payload)

    assert len(bounded["session"]["messages"]) == 30
    assert bounded["session"]["tool_calls"] == []


def test_done_tail_leaves_short_sessions_other_events_and_opt_out_alone(monkeypatch):
    short = {"session": {"messages": [{"role": "user", "content": "hi"}]}}
    assert bounded_journal_payload("done", short) is short
    token = {"text": "x" * 10}
    assert bounded_journal_payload("token", token) is token
    long_payload = {"session": {"messages": [{"role": "user"}] * 50}}
    monkeypatch.setenv("HERMES_WEBUI_RUN_JOURNAL_DONE_MESSAGES", "0")
    assert bounded_journal_payload("done", long_payload) is long_payload


def _age(path, days):
    old = time.time() - days * 86400
    os.utime(path, (old, old))


def _write_session(tmp_path, sid, active_stream_id=None):
    (tmp_path / f"{sid}.json").write_text(json.dumps({
        "session_id": sid, "title": "t", "created_at": 1, "updated_at": 1,
        "active_stream_id": active_stream_id, "messages": [],
    }), encoding="utf-8")


def test_prune_removes_old_finished_runs_and_keeps_recent_and_live_ones(tmp_path):
    # Finished long ago -> removed.
    append_run_event("s_done", "old_done", "token", {"text": "a"}, session_dir=tmp_path)
    append_run_event("s_done", "old_done", "stream_end", {}, session_dir=tmp_path)
    _age(_journal_path(tmp_path, "s_done", "old_done"), 30)
    # Finished recently -> kept.
    append_run_event("s_done", "new_done", "done", {}, session_dir=tmp_path)
    # Never finished, and its session still points at it -> kept (crash recovery).
    _write_session(tmp_path, "s_live", active_stream_id="crashed")
    append_run_event("s_live", "crashed", "token", {"text": "partial"}, session_dir=tmp_path)
    _age(_journal_path(tmp_path, "s_live", "crashed"), 30)
    # Never finished, session moved on -> removed, and the empty dir with it.
    _write_session(tmp_path, "s_moved", active_stream_id=None)
    append_run_event("s_moved", "abandoned", "token", {"text": "partial"}, session_dir=tmp_path)
    _age(_journal_path(tmp_path, "s_moved", "abandoned"), 30)
    # Never finished, session deleted -> removed.
    append_run_event("s_gone", "orphan", "token", {"text": "partial"}, session_dir=tmp_path)
    _age(_journal_path(tmp_path, "s_gone", "orphan"), 30)

    result = prune_run_journals(tmp_path, retention_days=7)

    assert result["scanned"] == 4
    assert result["removed"] == 3
    assert result["kept_active"] == 1
    assert result["removed_bytes"] > 0
    assert not _journal_path(tmp_path, "s_done", "old_done").exists()
    assert _journal_path(tmp_path, "s_done", "new_done").exists()
    assert _journal_path(tmp_path, "s_live", "crashed").exists()
    assert not (tmp_path / "_run_journal" / "s_moved").exists()
    assert not (tmp_path / "_run_journal" / "s_gone").exists()


def test_prune_finds_terminal_runs_whose_tail_is_one_long_line(tmp_path, monkeypatch):
    monkeypatch.setattr(rj, "_TAIL_PROBE_BYTES", 64)
    path = _journal_path(tmp_path, "s1", "r1")
    path.parent.mkdir(parents=True)
    with path.open("w", encoding="utf-8") as fh:
        fh.write(_raw_event_line(1, "done", "{" + '"t":"' + "y" * 5000 + '"}',
                                 terminal=True, terminal_state="completed", rid="r1"))
    _age(path, 30)
    _write_session(tmp_path, "s1", active_stream_id="r1")

    assert prune_run_journals(tmp_path, retention_days=7)["removed"] == 1


def test_prune_and_janitor_are_off_when_retention_is_zero(tmp_path, monkeypatch):
    append_run_event("s1", "r1", "stream_end", {}, session_dir=tmp_path)
    _age(_journal_path(tmp_path, "s1", "r1"), 365)
    monkeypatch.setenv("HERMES_WEBUI_RUN_JOURNAL_RETENTION_DAYS", "0")

    assert prune_run_journals(tmp_path)["removed"] == 0
    assert _journal_path(tmp_path, "s1", "r1").exists()
    assert start_retention_janitor() is False


def test_web_done_handler_takes_the_paging_cursor_from_a_tail_window():
    from pathlib import Path

    src = (Path(__file__).resolve().parents[1] / "static" / "messages.js").read_text()
    pos = src.index("S.session=d.session;S.messages=d.session.messages||[];")
    block = src[pos : pos + 800]

    assert "_messagesTruncated=!!d.session._messages_truncated" in block
    assert "_oldestIdx=d.session._messages_offset||0" in block


def test_live_done_sends_the_bounded_tail_redacted_after_the_cut():
    # The done event used to carry (and redact) the whole transcript every turn; clients
    # page older messages via msg_before, exactly as after the initial msg_limit load.
    from pathlib import Path

    src = (Path(__file__).resolve().parents[1] / "api" / "streaming.py").read_text(encoding="utf-8")
    bounded = src.find("bounded_journal_payload('done', {'session': raw_session")
    assert bounded != -1
    assert src.find("redact_session_data(_done['session'])", bounded) != -1
    assert "put('done', {'session': redact_session_data(raw_session)" not in src
