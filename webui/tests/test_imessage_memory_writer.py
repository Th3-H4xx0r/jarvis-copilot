"""iMessage bursts → transcript + fact memories."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.imessage_memory_writer as w  # noqa: E402
from api.imessage_memory import GAP_SECONDS, Burst, IMStore  # noqa: E402

LA = ZoneInfo("America/Los_Angeles")
T0 = 1_760_918_520.0  # Sun 19 Oct 2025 17:02 PDT
SAM = {"handle": "+15105550000", "label": "Sam Lee"}


class FakeMemory:
    def __init__(self):
        self.saved = []
        self.forgot = []

    def remember(self, body, **kw):
        self.saved.append({"body": body, **kw})
        return "id"

    def forget(self, **kw):
        self.forgot.append(kw)
        return 3


@pytest.fixture()
def st(tmp_path, monkeypatch):
    s = IMStore(tmp_path / "im.db")
    s.update_settings(enabled=True, agent={"model": "claude-haiku-5-5", "provider": "anthropic"})
    s.upsert_chats([{"guid": "one", "name": "Sam Lee", "is_group": False, "participants": [SAM]}])
    monkeypatch.setattr(w, "_zone", lambda: LA)
    return s


def _rows(*items):
    return [{"rowid": i, "ts": T0 + off, "sender": "Me" if me else "Sam Lee", "handle": "",
             "is_from_me": me, "text": text, "job_id": None}
            for i, (off, me, text) in enumerate(items, start=1)]


def _ingest(st, *items):
    st.ingest([{"guid": "one", **r} for r in _rows(*items)])


def _reply(summary="Sam shared his address.", facts=("Sam Lee's address is 12 Oak St, Oakland",)):
    return lambda ref, prompt: "Sure:\n```json\n" + json.dumps({"summary": summary, "facts": list(facts)}) + "\n```"


def test_transcript_header_and_lines_in_local_zone():
    burst = Burst("one", _rows((0, False, "my address is 12 Oak St"), (60, True, "thanks!")))
    (body, when), = w.transcript_memories(burst, {"participants": [SAM]}, LA, "Sam shared his address.")
    lines = body.split("\n")
    assert lines[0].startswith("iMessage with Sam Lee (+15105550000) — Sun 19 Oct 2025, 17:02–17:03 P")
    assert lines[1] == "Participants: Me, Sam Lee"
    assert lines[2] == "Summary: Sam shared his address."
    assert lines[3:] == ["[17:02] Sam Lee: my address is 12 Oak St", "[17:03] Me: thanks!"]
    assert when == T0


def test_transcript_splits_at_1500_repeating_header():
    burst = Burst("one", _rows(*[(i * 10, i % 2 == 0, "x" * 200) for i in range(20)]))
    parts = w.transcript_memories(burst, {"participants": [SAM]}, LA)
    assert len(parts) > 1
    assert all(len(body) <= w.MEMORY_CHUNK_CHARS for body, _ in parts)
    assert all(body.startswith("iMessage with Sam Lee") for body, _ in parts)
    assert sum(body.count("x" * 200) for body, _ in parts) == 20


def test_group_header_names_the_group():
    burst = Burst("grp", _rows((0, False, "hi all")))
    (body, _), = w.transcript_memories(burst, {"name": "Family", "is_group": True,
                                               "participants": [SAM]}, LA)
    assert body.startswith("iMessage with the group “Family” —")


def test_parse_extraction_tolerates_prose_and_caps_8():
    facts = [f"Fact number {i} is worth keeping" for i in range(12)] + ["too short", "Your verification code is 1234"]
    summary, got = w.parse_extraction("Here you go: " + json.dumps({"summary": "S", "facts": facts}) + " done")
    assert summary == "S" and len(got) == 8 and all("code" not in f for f in got)
    with pytest.raises(ValueError):
        w.parse_extraction("no json here")


def test_facts_stamped_with_person_and_date(st):
    st.update_settings(ask_facts=False)   # saved directly, no Store/Skip card
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"), (60, True, "got it"))
    mem = FakeMemory()
    assert w.close_once(st, T0 + 60 + GAP_SECONDS, memory=mem, complete=_reply()) == 1
    convo = [m for m in mem.saved if m["tags"] == "imessage,conversation"]
    facts = [m for m in mem.saved if m["tags"] == "imessage,fact"]
    assert convo[0]["source"] == "imessage:one:1-2:p1" and convo[0]["dedup"] is False
    assert "Summary: Sam shared his address." in convo[0]["body"]
    assert facts[0]["body"] == ("Sam Lee's address is 12 Oak St, Oakland (from an iMessage chat with "
                                "Sam Lee on Sun 19 Oct 2025 17:02 PDT)")
    assert facts[0]["source"] == "imessage:one:fact:1-2:f"
    assert st.totals() == {"bursts": 1, "pending": 0}


def test_burst_stored_without_facts_when_extraction_fails(st):
    _ingest(st, (0, False, "hello"))

    def boom(ref, prompt):
        raise RuntimeError("provider down")

    mem = FakeMemory()
    assert w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=boom) == 1
    assert [m["tags"] for m in mem.saved] == ["imessage,conversation"]
    assert "Summary:" not in mem.saved[0]["body"]


def test_closer_discards_bursts_for_unticked_chat(st):
    _ingest(st, (0, False, "hello"))
    st.set_pick("one", False)
    mem = FakeMemory()
    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply())
    assert mem.saved == [] and st.totals() == {"bursts": 0, "pending": 0}


def test_closer_waits_when_memory_inactive(st, monkeypatch):
    _ingest(st, (0, False, "hello"))
    monkeypatch.setattr(w, "memory_writer", lambda: None)
    assert w.close_once(st, T0 + GAP_SECONDS) == 0
    assert st.totals()["pending"] == 1


def test_resolve_model_choice_model_harness_default(monkeypatch):
    monkeypatch.setattr(w, "_default_model", lambda: "@ollama-cloud:gpt-oss")
    assert w.resolve_extraction_model({"model": "claude-haiku-5-5", "provider": "anthropic"}) == \
        ("@anthropic:claude-haiku-5-5", "model @anthropic:claude-haiku-5-5")
    monkeypatch.setattr(w, "_harness_model",
                        lambda hid: ("@anthropic:claude-sonnet-5-5", "harness Main → x") if hid == "main" else None)
    assert w.resolve_extraction_model({"harness_id": "main"})[0] == "@anthropic:claude-sonnet-5-5"
    # A missing harness falls back to the default model.
    assert w.resolve_extraction_model({"harness_id": "gone"})[0] == "@ollama-cloud:gpt-oss"

    class FakeStore:
        def effective(self, surface):
            return "main"

    import api.harness_store as hs
    monkeypatch.setattr(hs, "store_for_request", lambda: FakeStore())
    ref, label = w.resolve_extraction_model(None)
    assert ref == "@anthropic:claude-sonnet-5-5" and label.startswith("Default → harness")


def test_extract_slices_long_transcripts():
    calls = []

    def complete(ref, prompt):
        calls.append(prompt)
        return json.dumps({"summary": f"part {len(calls)}", "facts": [f"Fact {len(calls)} is a real fact"]})

    transcript = "\n".join("y" * 1000 for _ in range(30))
    summary, facts = w.extract(transcript, "@x:y", complete)
    assert len(calls) == 3 and summary == "part 1 part 2 part 3" and len(facts) == 3


def test_forget_chat_memories(st):
    mem = FakeMemory()
    assert w.forget_chat_memories("one", st=st, memory=mem) == 3
    assert mem.forgot == [{"source_prefix": "imessage:one:"}]


def test_forget_during_extraction_takes_the_memories_back(st):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    mem = FakeMemory()

    def complete(ref, prompt):
        st.forget_chat("one")                     # he presses Forget mid-call
        return _reply()(ref, prompt)

    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=complete)
    # Nothing was left buffered, so nothing was written at all.
    assert mem.saved == [] and st.totals() == {"bursts": 0, "pending": 0}


def test_forget_after_write_before_mark_is_undone(st, monkeypatch):
    _ingest(st, (0, False, "hello there friend"))
    mem = FakeMemory()
    real_mark = st.mark_burst

    def mark(burst, status):
        st.forget_chat("one")
        return real_mark(burst, status)

    monkeypatch.setattr(st, "mark_burst", mark)
    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply())
    assert {"source_prefix": "imessage:one:1-1:"} in mem.forgot
    assert st.totals() == {"bursts": 0, "pending": 0}


def test_refused_write_keeps_rows_for_retry(st):
    _ingest(st, (0, False, "hello there friend"))

    class Refusing(FakeMemory):
        def remember(self, body, **kw):
            return None

    mem = Refusing()
    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply())
    assert st.totals() == {"bursts": 0, "pending": 1}
    assert {"source_prefix": "imessage:one:1-1:"} in mem.forgot


def test_recover_undoes_a_burst_cut_off_mid_write(st):
    _ingest(st, (0, False, "hello there friend"))
    (burst,) = st.open_bursts(T0 + GAP_SECONDS)
    st.begin_burst(burst)                         # then the server restarted
    mem = FakeMemory()
    assert w.recover(st, memory=mem) == 1
    assert {"source_prefix": "imessage:one:1-1:"} in mem.forgot
    assert st.totals() == {"bursts": 0, "pending": 1}
    assert w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply()) == 1


def test_sources_dont_collide_by_prefix():
    a = Burst("g", _rows((0, False, "x")))
    a.rows[0]["rowid"] = 10
    pre_a, _ = w._sources(a)
    assert not f"{pre_a}".startswith("imessage:g:10-1:") and pre_a == "imessage:g:10-10:"
    assert not "imessage:g:10-100:p1".startswith(pre_a)


# ── fact cards ───────────────────────────────────────────────────────────
@pytest.fixture()
def pushes(monkeypatch):
    sent = []
    monkeypatch.setattr(w, "push_facts", lambda burst, chat, facts: sent.append(list(facts)) or 1)
    return sent


def test_live_burst_facts_become_cards(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    mem = FakeMemory()
    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply())
    assert [m["tags"] for m in mem.saved] == ["imessage,conversation"]   # transcript only
    (card,) = st.pending_facts()
    assert card["fact"] == "Sam Lee's address is 12 Oak St, Oakland" and card["chat_name"] == "Sam Lee"
    assert pushes == [["Sam Lee's address is 12 Oak St, Oakland"]]


def test_push_off_keeps_cards_without_push(st, pushes):
    st.update_settings(push_facts=False)
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply())
    assert st.pending_count() == 1 and pushes == []


def test_ask_off_saves_facts_directly(st, pushes):
    st.update_settings(ask_facts=False)
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    mem = FakeMemory()
    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply())
    assert "imessage,fact" in [m["tags"] for m in mem.saved]
    assert st.pending_count() == 0 and pushes == []


def test_backfill_facts_skip_cards(st, pushes):
    job = st.create_job(T0 - 10, T0 + 10)
    st.ingest([{"guid": "one", **r} for r in _rows((0, False, "my address is 12 Oak St"))], job_id=job["id"])
    st.update_job(job["id"], status="done")
    mem = FakeMemory()
    w.close_once(st, T0 + 20, memory=mem, complete=_reply())
    assert "imessage,fact" in [m["tags"] for m in mem.saved]
    assert st.pending_count() == 0 and pushes == []


def test_decide_store_and_skip(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply(
        facts=("Sam Lee's address is 12 Oak St, Oakland", "Sam Lee is moving in March")))
    a, b = st.pending_facts()
    mem = FakeMemory()
    assert w.decide_facts(st, ids=[a["id"]], store=True, memory=mem) == 1
    assert mem.saved[0]["source"] == "imessage:one:fact:1-1:f"
    assert mem.saved[0]["body"].startswith(a["fact"] + " (from an iMessage chat with Sam Lee")
    assert w.decide_facts(st, ids=[b["id"]], store=False, memory=mem) == 1
    assert len(mem.saved) == 1 and st.pending_count() == 0
    assert w.decide_facts(st, ids=[a["id"]], store=True, memory=mem) == 0   # already decided


def test_store_all_by_burst(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply(
        facts=("Sam Lee's address is 12 Oak St, Oakland", "Sam Lee is moving in March")))
    mem = FakeMemory()
    assert w.decide_facts(st, burst="one|1", store=True, memory=mem) == 2


def test_auto_store_after_24h(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply())
    mem = FakeMemory()
    import time as _time
    w.close_once(st, _time.time() + 86400 + 60, memory=mem)
    assert [m["tags"] for m in mem.saved] == ["imessage,fact"] and st.pending_count() == 0


def test_forget_race_deletes_cards(st, pushes, monkeypatch):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    real_mark = st.mark_burst

    def mark(burst, status):
        st.forget_chat("one")
        return real_mark(burst, status)

    monkeypatch.setattr(st, "mark_burst", mark)
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply())
    assert st.pending_count() == 0 and pushes == []


def test_push_facts_sends_one_alert_to_phones(monkeypatch):
    import api.pairing as pairing
    import api.push as push_mod
    calls = []
    monkeypatch.setattr(pairing, "list_devices", lambda: [
        {"push_token": "t1", "push_kind": "apns", "kind": "mobile-ios"},
        {"push_token": "t2", "push_kind": "apns", "kind": "desktop"}])
    monkeypatch.setattr(push_mod, "send", lambda kind, token, data, alert=None: calls.append((token, data, alert)) or {"ok": True})
    burst = Burst("one", _rows((0, False, "x")))
    assert w.push_facts(burst, {"participants": [SAM]}, ["Fact A is here", "Fact B is here"]) == 1
    token, data, alert = calls[0]
    assert token == "t1" and data == {"type": "imessage_facts", "burst": "one|1"}
    assert alert["title"] == "2 new facts from Sam Lee" and alert["category"] == "IMESSAGE_FACTS"
    assert alert["body"] == "Fact A is here — and 1 more"



def test_failed_card_write_goes_back_to_waiting(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply())

    class Refusing(FakeMemory):
        def remember(self, body, **kw):
            return None

    assert w.decide_facts(st, burst="one|1", store=True, memory=Refusing()) == 0
    assert st.pending_count() == 1


def test_forget_during_store_takes_the_fact_back(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    w.close_once(st, T0 + GAP_SECONDS, memory=FakeMemory(), complete=_reply())

    class ForgetsMidway(FakeMemory):
        def remember(self, body, **kw):
            st.forget_chat("one")                 # he presses Forget while it stores
            return super().remember(body, **kw)

    mem = ForgetsMidway()
    assert w.decide_facts(st, burst="one|1", store=True, memory=mem) == 0
    assert {"source_prefix": "imessage:one:fact:1-1:f"} in mem.forgot


def test_restart_releases_stuck_cards_and_no_duplicate_cards(st, pushes):
    _ingest(st, (0, False, "my address is 12 Oak St, Oakland"))
    (burst,) = st.open_bursts(T0 + GAP_SECONDS)
    st.begin_burst(burst)
    st.add_fact_cards(burst, "Sam Lee", [("Fact from a cut-off try", "b")], "imessage:one:fact:1-1:f")
    st.take_cards(burst="one|1")                  # claimed, then the server died
    mem = FakeMemory()
    w.recover(st, memory=mem)
    assert st.pending_count() == 1                # back to waiting...
    w.close_once(st, T0 + GAP_SECONDS, memory=mem, complete=_reply())
    assert [c["fact"] for c in st.pending_facts()] == ["Sam Lee's address is 12 Oak St, Oakland"]
