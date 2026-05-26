from __future__ import annotations

import itertools
import time as _time

import pytest

from agent import code_memory as cm
from agent import code_memory_index as idx


@pytest.fixture(autouse=True)
def _monotonic_ts(monkeypatch):
    """Give each write_entry a distinct, increasing timestamp (real entries are
    seconds apart; the second-resolution clock would otherwise collide in a test)."""
    counter = itertools.count()
    base = 1748000000
    real_gmtime = _time.gmtime  # capture before patching (same module object)

    def fake_gmtime(secs=None):
        return real_gmtime(base + next(counter))

    monkeypatch.setattr(cm.time, "gmtime", fake_gmtime)


def _seed(home):
    cm.write_entry("p1", "knowledge", "bug", "null deref in foo() when bar is empty", home=home)
    cm.write_entry("p1", "knowledge", "fix", "guard foo() with a None check on bar", home=home)
    cm.write_entry("p1", "knowledge", "gotcha", "prot= maps to watchlist_sector_protected_slots", home=home)
    cm.write_entry("p1", "sessions", "claude", "did the index; open: wire MCP", home=home)
    cm.write_entry("p2", "knowledge", "decision", "use SQLite FTS5 as a derived index", home=home)


# ── index build / search / get ───────────────────────────────────────────────
def test_search_recency_no_query(tmp_path):
    _seed(tmp_path)
    rows = idx.search(slug="p1", kind="knowledge", home=tmp_path)
    assert [r["entry_type"] for r in rows] == ["gotcha", "fix", "bug"]  # newest first
    assert all("body" not in r for r in rows)  # compact: no bodies
    assert all(r["id"].startswith("p1::knowledge::") for r in rows)


def test_search_query_ranks_relevant(tmp_path):
    _seed(tmp_path)
    rows = idx.search(slug="p1", kind="knowledge", query="foo", home=tmp_path)
    types = {r["entry_type"] for r in rows}
    assert types == {"bug", "fix"}  # only the two foo() entries match


def test_search_filters_by_type_and_paginates(tmp_path):
    _seed(tmp_path)
    only = idx.search(slug="p1", kind="knowledge", entry_type="fix", home=tmp_path)
    assert len(only) == 1 and only[0]["entry_type"] == "fix"
    page = idx.search(slug="p1", kind="knowledge", limit=1, offset=1, home=tmp_path)
    assert len(page) == 1 and page[0]["entry_type"] == "fix"


def test_search_query_with_special_chars_does_not_crash(tmp_path):
    _seed(tmp_path)
    # punctuation-heavy query must not raise an FTS syntax error
    assert idx.search(slug="p1", kind="knowledge", query="GET /backtests/{id} prot=0", home=tmp_path) is not None


def test_get_by_ids_returns_bodies_in_order(tmp_path):
    _seed(tmp_path)
    rows = idx.search(slug="p1", kind="knowledge", home=tmp_path)
    ids = [rows[2]["id"], rows[0]["id"]]  # bug, gotcha
    full = idx.get_by_ids(ids, home=tmp_path)
    assert [r["id"] for r in full] == ids
    assert "null deref" in full[0]["content"]
    assert full[0].get("content") and "first_line" not in full[0]


def test_counts_and_stats_and_project_counts(tmp_path):
    _seed(tmp_path)
    assert idx.counts("p1", home=tmp_path) == {"knowledge": 3, "sessions": 1}
    s = idx.stats(home=tmp_path)
    assert s["knowledge"] == 4 and s["sessions"] == 1 and s["projects"] == 2
    assert s["by_type"]["bug"] == 1 and s["by_type"]["decision"] == 1
    pc = idx.project_counts(home=tmp_path)
    assert pc["p1"]["knowledge"] == 3 and pc["p2"]["knowledge"] == 1


# ── staleness / rebuild ──────────────────────────────────────────────────────
def test_index_reflects_new_writes(tmp_path):
    _seed(tmp_path)
    assert idx.counts("p1", home=tmp_path)["knowledge"] == 3
    cm.write_entry("p1", "knowledge", "note", "a fourth fact", home=tmp_path)
    assert idx.counts("p1", home=tmp_path)["knowledge"] == 4  # checksum-gated re-sync


def test_index_reflects_deletes(tmp_path):
    _seed(tmp_path)
    rows = cm.read_entries("p1", "knowledge", home=tmp_path)
    cm.delete_entry("p1", "knowledge", rows[0]["ts"], home=tmp_path)
    assert idx.counts("p1", home=tmp_path)["knowledge"] == 2


def test_rebuild_is_idempotent(tmp_path):
    _seed(tmp_path)
    before = idx.search(slug="p1", kind="knowledge", home=tmp_path)
    idx.rebuild(home=tmp_path)
    idx.rebuild(home=tmp_path)
    after = idx.search(slug="p1", kind="knowledge", home=tmp_path)
    assert [r["id"] for r in before] == [r["id"] for r in after]  # ids stable across rebuilds


# ── digest ───────────────────────────────────────────────────────────────────
def test_digest_is_small_and_useful(tmp_path):
    _seed(tmp_path)
    d = cm.digest("p1", home=tmp_path)
    assert "3 knowledge" in d and "1 handoffs" in d
    assert "wire MCP" in d  # latest handoff first-line
    assert len(d) < 1200  # well under a ~300-token budget


# ── soft-length warning ──────────────────────────────────────────────────────
def test_long_knowledge_warns_but_saves(tmp_path):
    res = cm.write_entry("p1", "knowledge", "note", "x" * (cm.SOFT_ENTRY_CHARS + 50), home=tmp_path)
    assert "warning" in res
    assert cm.count_entries("p1", "knowledge", home=tmp_path) == 1  # still saved


def test_short_knowledge_no_warning(tmp_path):
    res = cm.write_entry("p1", "knowledge", "note", "short fact", home=tmp_path)
    assert "warning" not in res


# ── fallback to markdown when the index is unavailable ───────────────────────
def test_search_falls_back_to_markdown(tmp_path, monkeypatch):
    _seed(tmp_path)

    def boom(*a, **k):
        raise RuntimeError("index down")

    monkeypatch.setattr(idx, "search", boom)
    rows = cm.search("p1", kind="knowledge", query="foo", home=tmp_path)
    assert rows and {r["entry_type"] for r in rows} == {"bug", "fix"}
    assert all(r["id"].startswith("p1::knowledge::") for r in rows)


def test_get_by_ids_falls_back_to_markdown(tmp_path, monkeypatch):
    _seed(tmp_path)
    rows = cm.search("p1", kind="knowledge", home=tmp_path)
    target = rows[2]["id"]  # bug
    monkeypatch.setattr(idx, "get_by_ids", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("down")))
    full = cm.get_by_ids([target], home=tmp_path)
    assert full and "null deref" in full[0]["content"]


def test_same_timestamp_fallback_matches_index(tmp_path, monkeypatch):
    """Two entries sharing a ts must get distinct, matching ids from BOTH the
    index and the markdown fallback, and get_by_ids must resolve each correctly."""
    f = cm._file("pX", "knowledge", tmp_path)
    f.parent.mkdir(parents=True, exist_ok=True)
    ts = "2026-05-26T12:00:00Z"
    # write the file directly so both entries share one timestamp (file order: FIRST, SECOND)
    f.write_text(f"\n{cm._SEP}## {ts} \xb7 note\nFIRST entry\n"
                 f"\n{cm._SEP}## {ts} \xb7 fix\nSECOND entry\n", encoding="utf-8")
    idx_ids = {r["first_line"]: r["id"] for r in idx.search(slug="pX", kind="knowledge", home=tmp_path)}
    assert len(idx_ids) == 2 and idx_ids["FIRST entry"].endswith("::0") and idx_ids["SECOND entry"].endswith("::1")
    # fallback search produces the SAME ids
    monkeypatch.setattr(idx, "search", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("down")))
    fb_ids = {r["first_line"]: r["id"] for r in cm.search("pX", kind="knowledge", home=tmp_path)}
    assert fb_ids == idx_ids
    # fallback get_by_ids resolves the right body per ordinal
    monkeypatch.setattr(idx, "get_by_ids", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("down")))
    got = cm.get_by_ids([idx_ids["SECOND entry"]], home=tmp_path)
    assert got and got[0]["content"] == "SECOND entry"
