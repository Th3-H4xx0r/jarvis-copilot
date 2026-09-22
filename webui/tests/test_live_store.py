"""Live Jarvis storage: the invariants an ambient transcript depends on.

The two that carry the most weight are `seq` (every client's resume cursor) and
speaker identity (a voice keeps one id forever while its name is free to
change). Most of the rest guards deletion, because deletion here removes other
people's recordings and has to do exactly what the UI promised.
"""
from __future__ import annotations

import pytest

from api import config as api_config
from api import live_store


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(api_config, "STATE_DIR", tmp_path)
    live_store.reset_for_tests()
    yield tmp_path
    live_store.reset_for_tests()


def _seg(session_id, text, *, start=0, end=1000, speaker=""):
    return live_store.append_segment(
        session_id, ts_start_ms=start, ts_end_ms=end, text=text,
        speaker_id=speaker)


# ── seq, the resume cursor ─────────────────────────────────────────────────


def test_seq_counts_up_from_one_and_is_scoped_to_its_session():
    """Every client resumes with `after_seq`, so a repeated or shared seq would
    silently drop or duplicate utterances on the other device."""
    a = live_store.start_session(device_id="phone")["id"]
    b = live_store.start_session(device_id="glasses")["id"]

    assert [_seg(a, "one")["seq"], _seg(a, "two")["seq"]] == [1, 2]
    assert _seg(b, "elsewhere")["seq"] == 1, "seq must not be global"
    assert live_store.get_session(a)["last_seq"] == 2


def test_appending_to_an_unknown_session_raises_rather_than_inventing_one():
    with pytest.raises(KeyError):
        _seg("no-such-session", "hello")


def test_segments_after_returns_only_what_the_client_has_not_seen():
    s = live_store.start_session()["id"]
    for i in range(5):
        _seg(s, f"line {i}")
    later = live_store.segments_after(s, after_seq=3)
    assert [r["seq"] for r in later] == [4, 5]


# ── transcript search ─────────────────────────────────────────────────────


def test_search_finds_an_utterance_by_word():
    s = live_store.start_session()["id"]
    _seg(s, "the pod firmware ships tuesday")
    _seg(s, "unrelated chatter")
    hits = live_store.search_segments("firmware")
    assert [h["text"] for h in hits] == ["the pod firmware ships tuesday"]


def test_a_malformed_search_returns_nothing_instead_of_exploding():
    """The query comes from a text box and from the model. FTS5 raises on a
    stray quote; a 500 in the middle of a recording is the worse outcome."""
    s = live_store.start_session()["id"]
    _seg(s, "hello there")
    assert live_store.search_segments('unbalanced "') == []


# ── speaker identity ──────────────────────────────────────────────────────


def test_renaming_a_voice_keeps_every_past_utterance_attached():
    """The whole point of id-vs-name: rename freely, history follows."""
    s = live_store.start_session()["id"]
    voice = live_store.create_speaker()["id"]
    _seg(s, "something he said", speaker=voice)

    live_store.rename_speaker(voice, "Alex")
    live_store.rename_speaker(voice, "Alexander")

    assert live_store.get_speaker(voice)["name"] == "Alexander"
    assert live_store.segments_after(s)[0]["speaker_id"] == voice


def test_merging_two_clusters_relabels_history_and_keeps_the_name():
    """Diarization decides mid-session that two voices are one person."""
    s = live_store.start_session()["id"]
    keep = live_store.create_speaker()["id"]
    dupe = live_store.create_speaker(name="Alex")["id"]
    _seg(s, "first", start=0, end=1000, speaker=keep)
    _seg(s, "second", start=1000, end=3000, speaker=dupe)

    moved = live_store.merge_speakers(dupe, keep)

    assert moved == 1
    assert live_store.get_speaker(dupe) is None
    assert {r["speaker_id"] for r in live_store.segments_after(s)} == {keep}
    survivor = live_store.get_speaker(keep)
    assert survivor["name"] == "Alex", "a name the user typed must not be lost"
    assert survivor["segment_count"] == 2
    assert survivor["speech_ms"] == 3000


def test_assigning_a_canonical_speaker_confirms_a_provisional_segment():
    s = live_store.start_session()["id"]
    seq = _seg(s, "provisional line")["seq"]
    assert live_store.segments_after(s)[0]["label_state"] == "provisional"

    voice = live_store.create_speaker()["id"]
    live_store.assign_speaker(s, seq, voice, conf=0.91)

    row = live_store.segments_after(s)[0]
    assert (row["speaker_id"], row["label_state"]) == (voice, "confirmed")
    assert row["speaker_conf"] == pytest.approx(0.91)


def test_embeddings_are_only_returned_for_their_own_model():
    """Comparing vectors across checkpoints is meaningless, not just noisy, so
    the store refuses to hand them back together."""
    voice = live_store.create_speaker()["id"]
    live_store.add_embedding(voice, [0.1, 0.2, 0.3], model="ecapa-v1")
    live_store.add_embedding(voice, [9.0, 9.0, 9.0], model="other-v2")

    same = live_store.embeddings_for_model("ecapa-v1")
    assert len(same) == 1
    assert same[0]["vec"] == pytest.approx([0.1, 0.2, 0.3], abs=1e-6)


# ── digests ───────────────────────────────────────────────────────────────


def test_a_digest_is_searchable_and_remembers_where_the_window_ended():
    s = live_store.start_session()["id"]
    live_store.add_digest(s, seq_from=1, seq_to=12,
                          summary="agreed to ship the pod firmware",
                          topics=["firmware", "pod"])

    assert live_store.last_digest_seq(s) == 12
    assert [d["seq_to"] for d in live_store.search_digests("firmware")] == [12]


def test_session_rollups_do_not_move_the_window_cursor():
    """The end-of-session rollup spans everything; if it counted as a window the
    next window would think its ground had already been summarised."""
    s = live_store.start_session()["id"]
    live_store.add_digest(s, seq_from=1, seq_to=5, summary="window", scope="window")
    live_store.add_digest(s, seq_from=1, seq_to=99, summary="whole thing",
                          scope="session")
    assert live_store.last_digest_seq(s) == 5


# ── storage accounting and deletion ───────────────────────────────────────


def _chunk(session_id, name, size, *, ts0=0, ts1=300000):
    path = live_store.audio_dir(session_id) / name
    path.write_bytes(b"\0" * size)
    return live_store.register_audio(session_id, path, ts0_ms=ts0, ts1_ms=ts1)


def test_storage_is_attributed_to_speakers_by_how_long_they_talked():
    """Bytes per speaker cannot be measured — a chunk holds everyone — so the
    split follows speech time and the total still reconciles."""
    s = live_store.start_session()["id"]
    loud = live_store.create_speaker(name="Loud")["id"]
    quiet = live_store.create_speaker(name="Quiet")["id"]
    _seg(s, "talking a lot", start=0, end=9000, speaker=loud)
    _seg(s, "brief", start=9000, end=10000, speaker=quiet)
    _chunk(s, "a.opus", 1000)

    summary = live_store.storage_summary()

    assert summary["total_bytes"] == 1000
    by_name = {r["name"]: r["approx_bytes"] for r in summary["per_speaker_approx"]}
    assert by_name == {"Loud": 900, "Quiet": 100}
    assert summary["per_speaker_approx"][0]["name"] == "Loud", "sorted by size"


def test_storage_summary_survives_having_no_speech_at_all():
    """Division by zero on a session that recorded only silence."""
    s = live_store.start_session()["id"]
    _chunk(s, "silence.opus", 500)
    assert live_store.storage_summary()["total_bytes"] == 500


def test_deleting_a_session_removes_its_rows_and_its_files():
    s = live_store.start_session()["id"]
    _seg(s, "will be gone")
    live_store.add_digest(s, seq_from=1, seq_to=1, summary="gone too")
    chunk = _chunk(s, "b.opus", 400)

    result = live_store.delete_session(s)

    assert result["freed_bytes"] == 400
    assert live_store.get_session(s) is None
    assert live_store.segments_after(s) == []
    assert live_store.digests_for_session(s) == []
    assert live_store.search_segments("gone") == []
    assert not (live_store.audio_dir(s) / "b.opus").exists()
    assert chunk["bytes"] == 400


def test_forgetting_a_voice_drops_their_words_but_keeps_the_recording():
    """The surgical option the settings screen offers first: their audio is
    inside chunks shared with other people, so it stays."""
    s = live_store.start_session()["id"]
    them = live_store.create_speaker(name="Them")["id"]
    _seg(s, "something private", speaker=them)
    _chunk(s, "c.opus", 700)

    result = live_store.forget_speaker(them)

    assert result == {"forgot_speaker": them, "segments_removed": 1,
                      "digests_removed": 0, "audio_kept": True}
    assert live_store.get_speaker(them) is None
    assert live_store.search_segments("private") == []
    assert live_store.storage_summary()["total_bytes"] == 700


def test_deleting_a_voices_recordings_takes_the_chunks_they_overlap():
    """The blunt option. It removes whole chunks, which is why the dialog warns
    that other people's audio goes with them."""
    s = live_store.start_session()["id"]
    them = live_store.create_speaker()["id"]
    _seg(s, "inside the first chunk", start=1000, end=2000, speaker=them)
    _chunk(s, "overlaps.opus", 600, ts0=0, ts1=5000)
    _chunk(s, "later.opus", 300, ts0=600000, ts1=900000)

    result = live_store.delete_audio_with_speaker(them)

    assert result["chunks_deleted"] == 1
    assert result["freed_bytes"] == 600
    assert not (live_store.audio_dir(s) / "overlaps.opus").exists()
    assert (live_store.audio_dir(s) / "later.opus").exists()
    assert live_store.segments_after(s), "the words outlive the recording"


def test_a_chunk_orphaned_by_a_crash_is_adopted_rather_than_left_invisible():
    """Chunks are registered when they roll, so a crash mid-chunk leaves a real
    file with no row — missing from the storage total and, worse, missed by
    delete_session's unlink, so "delete this day" would leave audio behind."""
    s = live_store.start_session()["id"]
    orphan = live_store.audio_dir(s) / "mid-crash.opuspkt"
    orphan.write_bytes(b"\0" * 800)
    assert live_store.storage_summary()["total_bytes"] == 0, "invisible before"

    assert live_store.sweep_orphan_audio() == {"adopted": 1, "bytes": 800}

    assert live_store.storage_summary()["total_bytes"] == 800
    live_store.delete_session(s)
    assert not orphan.exists(), "adoption is what lets delete reach it"


def test_the_sweep_ignores_files_it_already_knows_and_unknown_sessions():
    """Running it at every startup must be idempotent, and a directory with no
    session row is not ours to adopt."""
    s = live_store.start_session()["id"]
    _chunk(s, "known.opus", 100)
    stray = live_store._audio_root() / "session-that-never-existed"
    stray.mkdir(parents=True, exist_ok=True)
    (stray / "whose.opus").write_bytes(b"\0" * 50)

    assert live_store.sweep_orphan_audio() == {"adopted": 0, "bytes": 0}
    assert live_store.sweep_orphan_audio() == {"adopted": 0, "bytes": 0}
    assert live_store.storage_summary()["total_bytes"] == 100


def test_deleting_a_day_takes_every_session_recorded_that_day():
    """The storage panel groups by day, so the day rows need to be actionable."""
    a = live_store.start_session()["id"]
    b = live_store.start_session()["id"]
    _chunk(a, "a.opus", 300)
    _chunk(b, "b.opus", 200)
    day = live_store.storage_summary()["per_day"][0]["day"]

    result = live_store.delete_day(day)

    assert result["sessions_deleted"] == 2
    assert result["freed_bytes"] == 500
    assert live_store.storage_summary()["total_bytes"] == 0
    assert live_store.get_session(a) is None and live_store.get_session(b) is None


def test_deleting_a_day_with_nothing_on_it_is_a_no_op():
    live_store.start_session()
    assert live_store.delete_day("1999-01-01") == {
        "day": "1999-01-01", "sessions_deleted": 0, "freed_bytes": 0}


def test_a_deleted_utterance_is_not_still_legible_in_the_database_file():
    """Unlinking a row leaves its bytes in SQLite's free pages, so `strings`
    prints a "deleted" conversation straight back. For a store of other
    people's speech, deleted has to mean unreadable."""
    s = live_store.start_session()["id"]
    secret = "zqxjkbrvwmp the account number is four seven one"
    _seg(s, secret)

    live_store.delete_session(s)

    raw = (live_store._db_path()).read_bytes()
    assert b"zqxjkbrvwmp" not in raw, "deleted text is still readable on disk"


def test_forgetting_a_voice_also_removes_digests_that_named_them():
    """The digest prompt deliberately keeps names and specifics, so a summary is
    a second indexed copy of what they said. Leaving it would make "forget this
    voice" untrue."""
    s = live_store.start_session()["id"]
    them = live_store.create_speaker(name="Them")["id"]
    other = live_store.create_speaker(name="Other")["id"]
    _seg(s, "their words", speaker=them)
    live_store.add_digest(s, seq_from=1, seq_to=1,
                          summary="Them said something memorable",
                          speaker_ids=[them, other])
    live_store.add_digest(s, seq_from=2, seq_to=3, summary="nobody in particular",
                          speaker_ids=[other])

    result = live_store.forget_speaker(them)

    assert result["digests_removed"] == 1
    assert live_store.search_digests("memorable") == []
    assert len(live_store.search_digests("nobody")) == 1, "others' digests stay"


def test_forgetting_a_voice_does_not_match_a_merely_similar_speaker_id():
    """speaker_ids is JSON, so the match must be on the quoted id — a bare
    substring would also delete digests belonging to a longer id."""
    s = live_store.start_session()["id"]
    short = live_store.create_speaker()["id"][:8]
    live_store.add_digest(s, seq_from=1, seq_to=1, summary="kept",
                          speaker_ids=[short + "extra"])

    live_store.forget_speaker(short)

    assert len(live_store.search_digests("kept")) == 1


@pytest.mark.parametrize("evil", ["../escape", "../../escape", "/tmp/escape",
                                  "", "not-hex", "0123456789abcdef"])
def test_an_unsafe_session_id_can_never_become_a_filesystem_path(evil):
    """`Path(root) / "/etc"` discards the root and ".." climbs out of it, so an
    unchecked id turns a delete into an rmdir anywhere. Ids are uuid4 hex
    wherever they are minted, so anything else is refused, not sanitised."""
    with pytest.raises(ValueError):
        live_store.audio_dir(evil)


def test_deleting_a_session_with_an_unsafe_id_touches_nothing_outside_the_root(tmp_path):
    """The proven exploit: rmdir of an empty directory outside STATE_DIR."""
    victim = tmp_path.parent / "victim_empty_dir"
    victim.mkdir(exist_ok=True)
    live_store.audio_dir(live_store.start_session()["id"])  # make the root exist

    live_store.delete_session("../../victim_empty_dir")

    assert victim.is_dir(), "delete escaped the audio root"
    victim.rmdir()


def test_the_summary_says_out_loud_that_per_speaker_bytes_are_estimated():
    """A number this soft must not be presented as measured; the UI renders
    this note, so the contract is worth pinning."""
    assert "estimated" in live_store.storage_summary()["note"]


def test_speech_from_an_unidentified_voice_is_reported_as_unattributed():
    """Until on-device identification lands, most segments have no speaker. The
    denominator used to count only LABELLED speech, so ten identified seconds of
    a two-hour recording were attributed the whole file — a 720x overstatement in
    the panel the user deletes from."""
    s = live_store.start_session()["id"]
    known = live_store.create_speaker(name="Known")["id"]
    _seg(s, "ten seconds of me", start=0, end=10_000, speaker=known)
    _seg(s, "two hours of unlabelled room", start=10_000, end=7_210_000)
    _chunk(s, "big.opus", 22_000_000)

    summary = live_store.storage_summary()

    mine = summary["per_speaker_approx"][0]["approx_bytes"]
    assert mine < 100_000, f"identified voice was blamed for {mine} bytes"
    assert summary["unattributed"]["approx_bytes"] > 21_000_000
    assert "unattributed" in summary["note"]


def test_reassigning_a_segment_does_not_leave_the_old_voice_holding_the_time():
    """The authority lane reassigns segments as a normal part of confirming a
    speaker. Hand-maintained counters never debited the previous holder, so a
    ghost kept speech it no longer owned and a later merge added it again."""
    s = live_store.start_session()["id"]
    a = live_store.create_speaker(name="A")["id"]
    b = live_store.create_speaker(name="B")["id"]
    seq = _seg(s, "who said this", start=0, end=10_000, speaker=a)["seq"]

    live_store.assign_speaker(s, seq, b)

    assert live_store.get_speaker(a)["speech_ms"] == 0
    assert live_store.get_speaker(a)["segment_count"] == 0
    assert live_store.get_speaker(b)["speech_ms"] == 10_000

    live_store.merge_speakers(a, b)
    assert live_store.get_speaker(b)["speech_ms"] == 10_000, "merge double-counted"
    assert live_store.get_speaker(b)["segment_count"] == 1


def test_merging_into_a_speaker_that_does_not_exist_is_refused():
    """Otherwise the segments are relabelled onto a dangling id and the only row
    that could name them is deleted — unnameable utterances whose speech time
    disappears from the storage panel."""
    s = live_store.start_session()["id"]
    a = live_store.create_speaker(name="A")["id"]
    _seg(s, "mine", speaker=a)

    with pytest.raises(KeyError):
        live_store.merge_speakers(a, "typo-not-a-speaker")

    assert live_store.get_speaker(a) is not None
    assert live_store.segments_after(s)[0]["speaker_id"] == a


def test_deleting_a_voices_audio_falls_back_when_timestamps_cannot_be_compared():
    """A chunk with unknown times, or a segment ingested without them, overlaps
    nothing — so the precise query deleted zero chunks and reported success. A
    privacy delete must not silently no-op."""
    s = live_store.start_session()["id"]
    them = live_store.create_speaker()["id"]
    _seg(s, "no timestamps on this one", start=0, end=0, speaker=them)
    _chunk(s, "unplaceable.opus", 900, ts0=1_700_000_000_000, ts1=1_700_000_300_000)

    result = live_store.delete_audio_with_speaker(them)

    assert result["chunks_deleted"] == 1
    assert result["whole_sessions"] is True, "must admit it was imprecise"
    assert live_store.storage_summary()["total_bytes"] == 0


def test_registering_the_same_chunk_twice_does_not_double_count_it():
    """The startup sweep can race a roll, and a client with constant timestamps
    can make the writer reuse a filename."""
    s = live_store.start_session()["id"]
    path = live_store.audio_dir(s) / "same.opus"
    path.write_bytes(b"\0" * 500)
    live_store.register_audio(s, path)
    live_store.register_audio(s, path)

    summary = live_store.storage_summary()
    assert summary["total_bytes"] == 500
    assert summary["chunks"] == 1


def test_forgetting_a_voice_removes_a_digest_that_named_them_only_in_prose():
    """Before identification confirms anyone, segments carry a provisional label
    with speaker_id NULL — so a digest can name a person while its speaker_ids
    list is empty. Matching on speaker_ids alone would leave that summary, and
    the summary is the searchable copy."""
    s = live_store.start_session()["id"]
    them = live_store.create_speaker(name="Them")["id"]
    seq = _seg(s, "their words", speaker=them)["seq"]
    live_store.add_digest(s, seq_from=seq, seq_to=seq,
                          summary="Them mentioned the thing", speaker_ids=[])

    result = live_store.forget_speaker(them)

    assert result["digests_removed"] == 1
    assert live_store.search_digests("mentioned") == []


def test_a_respooled_utterance_is_not_stored_twice():
    """A dropped socket makes the client re-send its spool, and a `seg` frame
    carries no client id — the server assigns seq, so seq-based dedupe cannot
    see the duplicate. Content plus span is the only identity available."""
    s = live_store.start_session()["id"]
    first = _seg(s, "we agreed on tuesday", start=1000, end=3000)
    again = _seg(s, "we agreed on tuesday", start=1000, end=3000)

    assert again["seq"] == first["seq"]
    assert len(live_store.segments_after(s)) == 1


def test_two_identical_words_without_timestamps_are_still_two_utterances():
    """The dedupe must not swallow real speech: without a span there is no
    identity, and two people saying "yes" are two utterances."""
    s = live_store.start_session()["id"]
    a = _seg(s, "yes", start=0, end=0)
    b = _seg(s, "yes", start=0, end=0)

    assert a["seq"] != b["seq"]
    assert len(live_store.segments_after(s)) == 2
