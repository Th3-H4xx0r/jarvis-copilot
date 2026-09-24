"""Everything a voice has said, newest first, a page at a time.

The Voices screens (phone, web, Mac) open a voice onto its whole history; a
cursor at each page's last line means pages never overlap or skip, even when
two lines start in the same millisecond of different sessions.
"""
import json

from api import live_store
from tests.test_live_ws import _get, isolated_state  # noqa: F401 — fixture used by name


def _lines(speaker_id, **query):
    params = "&".join(f"{k}={v}" for k, v in {"speaker_id": speaker_id, **query}.items())
    handler, claimed = _get(f"/api/live/speaker_lines?{params}")
    assert claimed
    return handler.status, json.loads(handler.wfile.getvalue() or b"{}")


def _session(started_at, title):
    sid = live_store.start_session(device_id="d", title=title)["id"]
    with live_store.connect() as conn:
        conn.execute("UPDATE live_session SET started_at=? WHERE id=?", (started_at, sid))
        conn.commit()
    return sid


def _say(sid, speaker_id, start_ms, text):
    row = live_store.append_segment(sid, ts_start_ms=start_ms, ts_end_ms=start_ms + 1000,
                                    text=text, speaker_id=speaker_id)
    return int(row["seq"])


def test_pages_run_newest_first_without_overlap(isolated_state):
    sam = live_store.create_speaker(kind="other", name="Sam")["id"]
    other = live_store.create_speaker(kind="other")["id"]
    old = _session(1000.0, "Monday")
    new = _session(2000.0, "Tuesday")
    for i in range(3):
        _say(old, sam, i * 1000, f"old {i}")
    for i in range(4):
        _say(new, sam, i * 1000, f"new {i}")
    _say(new, other, 500, "not sam")

    status, first = _lines(sam, limit=3)
    assert status == 200 and first["total"] == 7
    assert [line["text"] for line in first["lines"]] == ["new 3", "new 2", "new 1"]
    assert first["lines"][0]["session_title"] == "Tuesday" and first["next"]

    _status, second = _lines(sam, limit=3, before=first["next"])
    assert [line["text"] for line in second["lines"]] == ["new 0", "old 2", "old 1"]

    _status, third = _lines(sam, limit=3, before=second["next"])
    assert [line["text"] for line in third["lines"]] == ["old 0"]
    assert third["next"] is None


def test_a_line_carries_when_it_was_said_and_its_translation(isolated_state):
    sam = live_store.create_speaker(kind="other")["id"]
    sid = _session(1_700_000_000.0, "Call")
    seq = _say(sid, sam, 2500, "అమ్మా")
    live_store.set_translation(sid, seq, "Mom")
    _status, got = _lines(sam)
    line = got["lines"][0]
    assert line["translation"] == "Mom" and line["live_session_id"] == sid
    assert abs(line["at"] - 1_700_000_002.5) < 0.01


def test_an_unknown_voice_has_said_nothing(isolated_state):
    status, got = _lines("nobody")
    assert status == 200 and got == {"speaker_id": "nobody", "total": 0, "lines": [], "next": None}


def test_the_voice_is_required_and_a_page_is_bounded(isolated_state):
    status, _ = _lines("")
    assert status == 400
    sam = live_store.create_speaker(kind="other")["id"]
    sid = _session(1000.0, "t")
    for i in range(5):
        _say(sid, sam, i * 1000, str(i))
    _status, got = _lines(sam, limit=100000)
    assert len(got["lines"]) == 5
    status, _ = _lines(sam, before="garbage")
    assert status == 400


def test_a_line_carries_its_voice_s_name(isolated_state):
    # Without it the phone labels a line by the voice id's digits: his own voice
    # showed as "Me" on some lines and "Speaker 8162" (Me's id) on others.
    from api import live_ws
    me = live_store.create_speaker(kind="me", name="Me")["id"]
    sid = _session(1000.0, "t")
    _say(sid, me, 0, "hello")
    row = live_store.segments_after(sid, 0)[0]
    assert live_ws.segment_frame(row)["speaker_name"] == "Me"


def test_a_voice_s_samples_are_its_latest_lines(isolated_state):
    # Ordered by the time within a session, an old long session's lines came
    # before today's.
    sam = live_store.create_speaker(kind="other")["id"]
    old = _session(1000.0, "old")
    new = _session(9000.0, "new")
    _say(old, sam, 600000, "old but late in its session")
    _say(new, sam, 1000, "today")
    assert live_store.speaker_samples(sam, limit=1)[0]["text"] == "today"
