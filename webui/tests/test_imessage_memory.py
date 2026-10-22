"""iMessage memory store: which chats count, dedupe, and when a burst closes."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from api.imessage_memory import GAP_SECONDS, IMStore, normalize_handle  # noqa: E402

SAM = {"handle": "+1 (510) 555-0000", "label": "Sam Lee"}
T0 = 1_760_000_000.0


@pytest.fixture()
def st(tmp_path):
    s = IMStore(tmp_path / "im.db")
    s.update_settings(enabled=True)
    s.upsert_chats([
        {"guid": "one", "name": "Sam Lee", "is_group": False, "participants": [SAM]},
        {"guid": "grp", "name": "Family", "is_group": True,
         "participants": [SAM, {"handle": "mom@example.com", "label": "Mom"}]},
    ])
    return s


def _msg(guid, rowid, ts, text="hi", handle="+15105550000", me=False):
    return {"guid": guid, "rowid": rowid, "ts": ts, "sender": "Me" if me else "Sam Lee",
            "handle": "" if me else handle, "is_from_me": me, "text": text}


def test_normalize_handle():
    assert normalize_handle("+1 (510) 555-0000") == "5105550000"
    assert normalize_handle("Mom@Example.com ") == "mom@example.com"


def test_pick_defaults_one_to_one_on_group_off(st):
    assert st.chat_allowed("one") is True
    assert st.chat_allowed("grp") is False
    st.set_pick("grp", True)
    st.set_pick("one", False)
    assert st.chat_allowed("grp") is True
    assert st.chat_allowed("one") is False


def test_disabled_allows_nothing(st):
    st.update_settings(enabled=False)
    assert st.chat_allowed("one") is False


def test_skip_list_beats_explicit_pick(st):
    st.set_pick("grp", True)
    st.update_settings(skip=[{"handle": "5105550000", "label": "Sam Lee"}])
    assert st.chat_allowed("one") is False
    assert st.chat_allowed("grp") is False


def test_ingest_rejects_disallowed_chats(st):
    counts = st.ingest([_msg("grp", 1, T0), _msg("one", 2, T0), _msg("nope", 3, T0)])
    assert counts == {"accepted": 1, "duplicate": 0, "rejected": 2}


def test_ingest_is_idempotent_on_same_rowid(st):
    st.ingest([_msg("one", 5, T0)])
    assert st.ingest([_msg("one", 5, T0)])["duplicate"] == 1


def test_ingest_drops_rowids_inside_stored_bursts(st):
    st.ingest([_msg("one", 10, T0), _msg("one", 12, T0 + 60)])
    (burst,) = st.open_bursts(T0 + 60 + GAP_SECONDS)
    st.mark_burst(burst, "stored")
    job = st.create_job(T0 - 3600, T0 + 3600)
    counts = st.ingest([_msg("one", 10, T0), _msg("one", 11, T0 + 30), _msg("one", 13, T0 + 90)],
                       job_id=job["id"])
    assert counts == {"accepted": 1, "duplicate": 2, "rejected": 0}
    assert st.job(job["id"])["skipped"] == 2 and st.job(job["id"])["status"] == "running"


def test_new_chat_details_ride_on_message(st):
    m = _msg("new", 1, T0)
    m.update(chat_name="Priya", is_group=False, participants=[{"handle": "+14155550000", "label": "Priya"}])
    assert st.ingest([m])["accepted"] == 1
    assert st.chat("new")["name"] == "Priya"


def test_segments_on_30_minute_gap(st):
    st.ingest([_msg("one", 1, T0), _msg("one", 2, T0 + 600),
               _msg("one", 3, T0 + 600 + GAP_SECONDS), _msg("one", 4, T0 + 700 + GAP_SECONDS)])
    bursts = st.open_bursts(T0 + 10 * GAP_SECONDS)
    assert [[r["rowid"] for r in b.rows] for b in bursts] == [[1, 2], [3, 4]]


def test_burst_waits_until_quiet(st):
    st.ingest([_msg("one", 1, T0), _msg("one", 2, T0 + 60, me=True)])
    assert st.open_bursts(T0 + 60 + GAP_SECONDS - 1) == []
    assert len(st.open_bursts(T0 + 60 + GAP_SECONDS)) == 1


def test_backfill_burst_closes_when_job_done(st):
    job = st.create_job(T0 - 86400, T0)
    st.ingest([_msg("one", 1, T0 - 7200), _msg("one", 2, T0 - 7100)], job_id=job["id"])
    assert st.open_bursts(T0 + 10) == []          # job still uploading
    st.update_job(job["id"], status="done")
    (burst,) = st.open_bursts(T0 + 10)
    st.mark_burst(burst, "stored")
    assert st.job(job["id"])["stored"] == 1
    assert st.chat("one")["remembered"] == 1


def test_create_job_refuses_second_active(st):
    st.create_job(T0 - 10, T0)
    with pytest.raises(ValueError):
        st.create_job(T0 - 10, T0)


def test_forget_chat_clears_bursts_so_backfill_can_redo(st):
    st.ingest([_msg("one", 1, T0)])
    (burst,) = st.open_bursts(T0 + GAP_SECONDS)
    st.mark_burst(burst, "stored")
    st.forget_chat("one")
    assert st.ingest([_msg("one", 1, T0)])["accepted"] == 1


def test_dedupe_needs_the_time_to_match_too(st):
    """A stored burst with ROWIDs 100 and 900 doesn't swallow ROWID 500 from another day."""
    st.ingest([_msg("one", 100, T0), _msg("one", 900, T0 + 60)])
    (burst,) = st.open_bursts(T0 + 60 + GAP_SECONDS)
    st.mark_burst(burst, "stored")
    assert st.ingest([_msg("one", 500, T0 + 5 * 86400)])["accepted"] == 1


def test_mark_burst_refuses_a_forgotten_burst(st):
    st.ingest([_msg("one", 1, T0)])
    (burst,) = st.open_bursts(T0 + GAP_SECONDS)
    st.forget_chat("one")
    assert st.mark_burst(burst, "stored") is False
    assert st.totals() == {"bursts": 0, "pending": 0} and st.chat("one")["remembered"] == 0


def test_stale_jobs_expire_so_they_cant_block(st):
    job = st.create_job(T0 - 3600, T0)
    st.ingest([_msg("one", 1, T0 - 600)], job_id=job["id"])          # running
    assert st.open_bursts(T0 + 10) == []
    st.expire_jobs(__import__("time").time() + 3 * 3600)
    assert st.job(job["id"])["status"] == "error"
    assert len(st.open_bursts(T0 + 10)) == 1
    st.create_job(T0 - 10, T0)                                          # no longer busy


def test_switching_on_stamps_enabled_at(st, tmp_path):
    fresh = IMStore(tmp_path / "fresh.db")
    assert fresh.settings()["enabled_at"] is None
    fresh.update_settings(enabled=True)
    first = fresh.settings()["enabled_at"]
    fresh.update_settings(enabled=True)                                 # already on: unchanged
    assert first and fresh.settings()["enabled_at"] == first


# ── fact cards ───────────────────────────────────────────────────────────
def _carded(st):
    st.ingest([_msg("one", 1, T0)])
    (burst,) = st.open_bursts(T0 + GAP_SECONDS)
    st.add_fact_cards(burst, "Sam Lee", [("Sam's address is 12 Oak St", "Sam's address is 12 Oak St (stamp)"),
                                          ("Sam likes tacos al pastor", "Sam likes tacos al pastor (stamp)")],
                      "imessage:one:fact:1-1:f")
    return burst


def test_settings_defaults_ask_and_push_on(st):
    assert st.settings()["ask_facts"] is True and st.settings()["push_facts"] is True


def test_cards_roundtrip(st):
    _carded(st)
    cards = st.pending_facts()
    assert [c["fact"] for c in cards] == ["Sam's address is 12 Oak St", "Sam likes tacos al pastor"]
    assert cards[0]["chat_name"] == "Sam Lee" and cards[0]["burst"] == "one|1"
    assert cards[0]["expires_at"] - cards[0]["at"] > 0 and "body" not in cards[0]
    assert st.pending_count() == 2


def test_decide_is_idempotent(st):
    _carded(st)
    first = st.take_cards(burst="one|1")
    assert len(first) == 2 and first[0]["body"].endswith("(stamp)")
    assert st.take_cards(burst="one|1") == []            # the other tap gets nothing
    st.finish_cards([c["id"] for c in first], "stored")
    assert st.pending_count() == 0


def test_forget_deletes_cards(st):
    _carded(st)
    st.forget_chat("one")
    assert st.pending_facts() == [] and st.take_cards(burst="one|1") == []


def test_expired_cards(st):
    _carded(st)
    import time as _time
    assert st.expired_cards(_time.time()) == []
    assert len(st.expired_cards(_time.time() + 86400 + 5)) == 2
    assert st.pending_count() == 0                       # claimed for auto-store


def test_released_cards_return_to_pending(st):
    _carded(st)
    ids = [c["id"] for c in st.take_cards(burst="one|1")]
    st.release_cards(ids)
    assert st.pending_count() == 2



def test_job_progress_and_analyzing_lifecycle(st):
    job = st.create_job(T0 - 3600, T0)
    st.ingest([_msg("one", 1, T0 - 600), _msg("one", 2, T0 - 590)], job_id=job["id"])
    st.update_job(job["id"], status="analyzing")
    j = st.job(job["id"])
    assert j["received"] == 2 and j["analyzed"] == 0
    assert st.active_job()["id"] == job["id"]              # still in progress
    with pytest.raises(ValueError):
        st.create_job(T0 - 10, T0)                         # one at a time
    (burst,) = st.open_bursts(T0 + 10)                     # analyzing rows can close
    st.mark_burst(burst, "stored")
    assert st.job(job["id"])["analyzed"] == 2
    assert st.finish_analyzed_jobs() == 1 and st.job(job["id"])["status"] == "done"


def test_stop_while_analyzing_drops_unread_rows(st):
    job = st.create_job(T0 - 3600, T0)
    st.ingest([_msg("one", 1, T0 - 600)], job_id=job["id"])
    st.update_job(job["id"], status="analyzing")
    st.stop_job(job["id"])
    assert st.job(job["id"])["status"] == "stopped" and st.totals()["pending"] == 0


def test_waiting_threads_are_chats_whose_last_word_was_theirs(st):
    from api.imessage_memory import Burst
    st.upsert_chats([{"guid": "two", "name": "Priya Rao", "is_group": False,
                      "participants": [{"handle": "+14155550000", "label": "Priya Rao"}]}])
    st.ingest([_msg("one", 1, T0, "see you at 7?"), _msg("one", 2, T0 + 60, "you there?")])
    st.ingest([_msg("two", 5, T0, "lunch?", handle="+14155550000"), _msg("two", 6, T0 + 30, "yes!", me=True)])
    for b in st.open_bursts(T0 + 10 * GAP_SECONDS):
        st.mark_burst(b, "stored")
    waiting = st.waiting_threads(T0 - 1)
    assert [(w["guid"], w["last_sender"]) for w in waiting] == [("one", "Sam Lee")]
    # A reply he sends later (still buffered) means it no longer waits on him.
    st.ingest([_msg("one", 3, T0 + 3000, "on my way", me=True)])
    assert st.waiting_threads(T0 - 1) == []
    # Messages still buffered count too.
    st.ingest([_msg("two", 7, T0 + 4000, "did you leave?", handle="+14155550000")])
    assert [w["guid"] for w in st.waiting_threads(T0 - 1)] == ["two"]
