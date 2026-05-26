from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def _cli():
    from jc_client import cli
    return cli


# ── _distill_parse: tolerate prose around the JSON array ──────────────────────
def test_distill_parse_plain_array():
    cli = _cli()
    assert cli._distill_parse('[{"i":0,"action":"keep"}]') == [{"i": 0, "action": "keep"}]


def test_distill_parse_with_trailing_prose():
    cli = _cli()
    out = cli._distill_parse('Here is the plan:\n[{"i":0,"action":"drop"}]\nNote: arrays like [1,2] are fine.')
    assert out == [{"i": 0, "action": "drop"}]


def test_distill_parse_garbage_returns_none():
    cli = _cli()
    assert cli._distill_parse("sorry, I can't do that") is None
    assert cli._distill_parse('{"not":"an array"}') is None


# ── distill --apply must not delete a kept entry that shares a timestamp ───────
class _FakeCmc:
    """Minimal stand-in for code_memory_client used by _cm_distill."""
    NotPaired = RuntimeError

    def __init__(self, rows, plan_json):
        self._rows = rows
        self._plan = plan_json
        self.deleted = []   # (slug, kind, ts)
        self.stored = []    # (slug, kind, entry_type, content)

    def current_slug(self):
        return "proj"

    def recall(self, slug, kind, limit=500):
        return self._rows

    def ask_agent(self, prompt, timeout=300.0):
        return self._plan

    def delete_entry(self, slug, kind, ts):
        self.deleted.append((slug, kind, ts))

    def store(self, slug, kind, entry_type, content):
        self.stored.append((slug, kind, entry_type, content))


def test_distill_apply_skips_delete_when_kept_shares_timestamp():
    cli = _cli()
    SHARED = "2026-05-26T12:00:00Z"
    rows = [
        {"ts": SHARED, "entry_type": "note", "content": "DROP me (run-specific)"},
        {"ts": SHARED, "entry_type": "gotcha", "content": "KEEP me (durable)"},
        {"ts": "2026-05-26T12:00:05Z", "entry_type": "note", "content": "lone drop"},
    ]
    # plan: drop index 0 and 2, keep index 1
    plan = '[{"i":0,"action":"drop"},{"i":2,"action":"drop"}]'
    cmc = _FakeCmc(rows, plan)
    rc = cli._cm_distill(cmc, SimpleNamespace(project="", apply=True))
    assert rc == 0
    # The shared timestamp must NOT be deleted (would nuke the kept gotcha);
    # the lone-timestamp drop is safe to delete.
    assert (("proj", "knowledge", SHARED) not in cmc.deleted)
    assert ("proj", "knowledge", "2026-05-26T12:00:05Z") in cmc.deleted


def test_distill_apply_rewrite_and_drop_on_distinct_timestamps():
    cli = _cli()
    rows = [
        {"ts": "2026-05-26T12:00:00Z", "entry_type": "note", "content": "x" * 800},
        {"ts": "2026-05-26T12:00:01Z", "entry_type": "note", "content": "stale run 404780 +152%"},
    ]
    plan = '[{"i":0,"action":"rewrite","entry_type":"gotcha","content":"short durable fact"},{"i":1,"action":"drop"}]'
    cmc = _FakeCmc(rows, plan)
    rc = cli._cm_distill(cmc, SimpleNamespace(project="", apply=True))
    assert rc == 0
    assert ("proj", "knowledge", "2026-05-26T12:00:00Z") in cmc.deleted
    assert ("proj", "knowledge", "2026-05-26T12:00:01Z") in cmc.deleted
    assert ("proj", "knowledge", "gotcha", "short durable fact") in cmc.stored


def test_distill_dry_run_changes_nothing():
    cli = _cli()
    rows = [{"ts": "2026-05-26T12:00:00Z", "entry_type": "note", "content": "essay"}]
    cmc = _FakeCmc(rows, '[{"i":0,"action":"drop"}]')
    rc = cli._cm_distill(cmc, SimpleNamespace(project="", apply=False))
    assert rc == 0 and cmc.deleted == [] and cmc.stored == []
