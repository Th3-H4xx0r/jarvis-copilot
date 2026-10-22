"""One-time backfill + cleanup: backup, Live rewrite, local stamps, dedupe, map."""
import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from plugins.memory.jarvis_memory import cleanup
from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore

CT = ZoneInfo("America/Chicago")
UTC = ZoneInfo("UTC")


@pytest.fixture
def env(tmp_path):
    s = MemoryStore(tmp_path / "memory" / "memory.db", tmp_path / "memory" / "vault")
    e = FakeEmbedder(dim=64)

    def add(body, source, when=1_790_000_000.0, tags="fact"):
        return s.add_chunk(GLOBAL_NS, body, source, when, 1.0, tags,
                           embedding=e.embed_one(body), signature=e.signature, dim=e.dim)
    return s, e, add


def _no_model(prompt, n):
    return "[]"


def test_backup_written_first(env):
    s, e, add = env
    add("Pranav lives in Houston.", "fact:extracted")
    path = cleanup.backup(s)
    assert Path(path).exists() and Path(path).parent.name == "backups"
    import sqlite3
    assert sqlite3.connect(path).execute("SELECT COUNT(*) FROM chunks").fetchone()[0] == 1


def test_live_rewrite_drops_lines(env):
    s, e, add = env
    keep = add("Live conversation on Tuesday 22 September 2026, 21:31–21:32 UTC (recording abcdef12)\n"
               "Speakers: Pranav, Brenda\nSummary: They planned the lesson.\n"
               "[21:31:05] Pranav: Are you there?\n[21:32:05] Brenda: Yes.", "live:s1:1-2",
               tags="live,conversation")
    gone = add("Live conversation on Tuesday 22 September 2026, 22:00–22:01 UTC (recording abcdef12)\n"
               "Speakers: Pranav\n[22:00:05] Pranav: hmm", "live:s1:3-4", tags="live,conversation")
    report = cleanup.run(s, e, zone=CT, complete=_no_model)
    [c] = s.get_chunks([keep])
    assert "Summary: They planned the lesson." in c.body and "Are you there" not in c.body
    assert s.count_chunks(GLOBAL_NS) == 1  # the one with no summary is hidden, not deleted
    assert s._conn.execute("SELECT status FROM chunks WHERE id=?", (gone,)).fetchone()[0] == "hidden"
    assert report["counts"]["live_rewritten"] == 2


def test_restamp_utc_to_local(env):
    s, e, add = env
    cid = add("Arnav suggested parking near the venue. (from an iMessage chat with the group "
              "\"F1 gc\" on Thu 22 Oct 2026 01:37 UTC)", "imessage:g:1-2:f", when=1_792_978_620.0)
    cleanup.run(s, e, zone=CT, complete=_no_model)
    [c] = s.get_chunks([cid])
    assert c.body.endswith("on Wed 21 Oct 2026 20:37 CDT)")


def test_dedupe_merges_sources_and_hides(env):
    s, e, add = env
    first = add("Parking near COTA is about $50 a day.", "imessage:a:1-1:f", when=1.0)
    s.dequeue([first])
    # A copy written before merging existed (dedup off), with its own source.
    second = s.add_chunk(GLOBAL_NS, "Parking near COTA is about $50 a day!", "imessage:b:2-2:f", 2.0, 1.0,
                         "imessage,fact", embedding=e.embed_one("Parking near COTA is about $50 a day."),
                         signature=e.signature, dim=e.dim)
    report = cleanup.run(s, e, zone=CT, complete=_no_model)
    assert s.count_chunks(GLOBAL_NS) == 1
    assert s.sources_of(first) == ["imessage:a:1-1:f", "imessage:b:2-2:f"]
    assert report["counts"]["merged"] == 1
    assert report["examples"]["merged"][0]["id"] == second


def test_enrich_runs_over_everything_and_report_written(env, tmp_path):
    s, e, add = env
    a = add("Pranav is going to the F1 race at COTA", "fact:extracted")
    b = add("The user has a father.", "fact:extracted")

    def model(prompt, n):
        return json.dumps([
            {"id": a, "kind": "plan", "importance": 8, "trivial": False, "event_start": "2026-10-24T09:00",
             "event_end": None, "entities": [], "slots": "venue: Circuit of the Americas", "supersedes": []},
            {"id": b, "kind": "fact", "importance": 1, "trivial": True, "event_start": None,
             "event_end": None, "entities": [], "slots": "", "supersedes": []}])
    report = cleanup.run(s, e, zone=CT, complete=model)
    assert report["counts"]["enriched"] == 1 and report["counts"]["hidden_trivial"] == 1
    assert report["examples"]["hidden_trivial"][0]["id"] == b
    saved = json.loads((tmp_path / "memory" / "cleanup_report.json").read_text())
    assert saved["counts"] == report["counts"] and saved["backup"]


def test_resume_skips_done(env):
    s, e, add = env
    a = add("Pranav likes omakase", "fact:extracted")
    calls = []

    def model(prompt, n):
        calls.append(prompt)
        return json.dumps([{"id": a, "kind": "preference", "importance": 5, "trivial": False,
                            "event_start": None, "event_end": None, "entities": [], "slots": "",
                            "supersedes": []}])
    cleanup.run(s, e, zone=CT, complete=model)
    cleanup.run(s, e, zone=CT, complete=model)
    assert len(calls) == 1  # mapped once; the second run finds nothing left


def test_restore_hidden(env):
    s, e, add = env
    cid = add("The user has a brother.", "fact:extracted")
    s.set_status([cid], "hidden")
    assert cleanup.restore_hidden(s, [cid]) == 1
    assert s.count_chunks(GLOBAL_NS) == 1
