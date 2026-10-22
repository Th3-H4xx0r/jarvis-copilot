"""One-time backfill + cleanup of the memory store (his "auto-clean + report").

Backs up memory.db, then: Live windows lose their transcript lines (summary +
link only; a window with no summary is hidden), "… UTC" stamps become his
local time, near-duplicates merge (the earliest keeps every source, the copy
is hidden), and every memory not yet mapped goes through the map pass —
which hides trivia and marks what newer memories replaced as past. Nothing is
deleted; hidden rows can be restored from the report. Each step skips work
already done, so a crashed run simply runs again.
"""
from __future__ import annotations

import json
import logging
import re
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional

from .textq import same_specifics

logger = logging.getLogger(__name__)

DEDUP_THRESHOLD = 0.92
EXAMPLES = 10
_LINE = re.compile(r"^\[\d{2}:\d{2}:\d{2}\] ", re.MULTILINE)
_STAMP = re.compile(
    r"(?P<dow>(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*) (?P<d>\d{1,2}) (?P<mon>[A-Z][a-z]+) (?P<y>\d{4})"
    r"(?P<sep>,? (?:at )?)(?P<h>\d{2}):(?P<m>\d{2})(?:–(?P<h2>\d{2}):(?P<m2>\d{2}))? UTC")


def _home_of(store) -> Path:
    return Path(store.db_path).parent


def report_path(store) -> Path:
    return _home_of(store) / "cleanup_report.json"


def backup(store) -> str:
    folder = _home_of(store) / "backups"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"memory-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.db"
    dest = sqlite3.connect(str(path))
    try:
        with store._lock:
            store._conn.backup(dest)
    finally:
        dest.close()
    return str(path)


def _local_stamp(m: re.Match, zone) -> str:
    long_month = len(m["mon"]) > 3
    try:
        start = datetime.strptime(f"{m['d']} {m['mon'][:3]} {m['y']} {m['h']}:{m['m']}", "%d %b %Y %H:%M")
    except ValueError:
        return m.group(0)
    start = start.replace(tzinfo=timezone.utc).astimezone(zone)
    dow = f"{start:%A}" if len(m["dow"]) > 3 else f"{start:%a}"
    mon = f"{start:%B}" if long_month else f"{start:%b}"
    out = f"{dow} {start.day} {mon} {start.year}{m['sep']}{start:%H:%M}"
    if m["h2"]:
        end_utc = datetime.strptime(f"{m['d']} {m['mon'][:3]} {m['y']} {m['h2']}:{m['m2']}", "%d %b %Y %H:%M")
        end = end_utc.replace(tzinfo=timezone.utc).astimezone(zone)
        out += f"–{end:%H:%M}"
    return out + f" {start:%Z}"


def restamp(body: str, zone) -> str:
    return _STAMP.sub(lambda m: _local_stamp(m, zone), body)


def _rewrite(store, embedder, cid, body, slots="", reembed=True):
    vec = None
    if reembed:
        try:
            vec = embedder.embed_one(body + (" " + slots if slots else ""))  # keep the slot-augmented key
        except Exception:
            pass
    store.update_body(cid, body, embedding=vec, signature=embedder.signature if vec else None,
                      dim=embedder.dim if vec else None)


def _example(store, cid) -> dict:
    c = next(iter(store.get_chunks([cid])), None)  # get_chunks reads hidden rows too
    return {"id": cid, "body": " ".join(c.body.split())[:200] if c else ""}


STALE_S = 180  # no progress note for this long = that run is gone


def request_stop(store) -> None:
    """Ask a running cleanup (in this or any process) to stop after its
    current batch. Everything done so far stays; running again continues."""
    store.kv_set("__cleanup__", "stop", "1")


def _stop_requested(store) -> bool:
    return store.kv_get("__cleanup__", "stop") == "1"


def progress(store) -> Optional[dict]:
    """The running cleanup's progress (any process), or None."""
    try:
        state = json.loads(store.kv_get("__cleanup__", "progress") or "null")
    except ValueError:
        return None
    if not isinstance(state, dict) or time.time() - float(state.get("at") or 0) > STALE_S:
        return None
    return state


def run(store, embedder, *, zone, complete: Optional[Callable[[str, int], str]] = None,
        progress: Optional[Callable[[dict], None]] = None, workers: int = 6) -> dict:
    from .enrich import drain

    counts = {"merged": 0, "hidden_trivial": 0, "superseded": 0, "live_rewritten": 0,
              "restamped": 0, "enriched": 0, "failed": 0}
    examples: Dict[str, List[dict]] = {k: [] for k in ("merged", "hidden_trivial", "superseded",
                                                       "live_rewritten", "restamped")}
    started = time.time()
    hidden_ids: Dict[str, List[str]] = {"merged": [], "hidden_trivial": [], "live_no_summary": []}

    store.kv_set("__cleanup__", "stop", "")
    stopped = {"flag": False}

    def halted():
        if not stopped["flag"] and _stop_requested(store):
            stopped["flag"] = True
        return stopped["flag"]

    def note(step, done=0, total=0):
        state = {"step": step, "done": done, "total": total, "started_at": started, "at": time.time()}
        store.kv_set("__cleanup__", "progress", json.dumps(state))
        if progress:
            progress(state)

    def keep(kind, cid):
        if len(examples[kind]) < EXAMPLES:
            examples[kind].append(_example(store, cid))

    note("backup")
    backup_path = backup(store)

    # 1. Live windows: summary + link only.
    live = store.active_ids(source_prefix="live:")
    for i, chunk in enumerate(store.get_chunks(live)):
        if i % 20 == 0 and halted():
            break
        if not _LINE.search(chunk.body):
            continue
        head = [l for l in chunk.body.splitlines() if l.strip() and not _LINE.match(l)]
        if not any(l.startswith("Summary:") for l in head):
            store.set_status([chunk.id], "hidden")
            hidden_ids["live_no_summary"].append(chunk.id)
        else:
            _rewrite(store, embedder, chunk.id, "\n".join(head), chunk.slots)
        if not chunk.source_ref:
            store.set_map_fields(chunk.id, source_ref=":".join(chunk.source.split(":")[:3]))
        counts["live_rewritten"] += 1
        keep("live_rewritten", chunk.id)
        if i % 50 == 0:
            note("live", i, len(live))

    # 2. "… UTC" stamps → his local time.
    ids = store.active_ids()
    for i, chunk in enumerate(store.get_chunks(ids)):
        if i % 200 == 0 and halted():
            break
        if " UTC" not in chunk.body:
            continue
        body = restamp(chunk.body, zone)
        if body != chunk.body:
            # Same meaning, local clock: keep the vector (no embed per memory).
            _rewrite(store, embedder, chunk.id, body, chunk.slots, reembed=False)
            counts["restamped"] += 1
            keep("restamped", chunk.id)
        if i % 200 == 0:
            note("stamps", i, len(ids))

    # 3. Near-duplicates: the earliest keeps every source; the copy is hidden.
    ids = store.active_ids()
    hidden = set()
    by_id = {c.id: c for c in store.get_chunks(ids)}
    for i, cid in enumerate(ids):
        if i % 100 == 0 and halted():
            break
        if cid in hidden:
            continue
        chunk = by_id.get(cid)
        vec = store.vector_of(cid, embedder.signature)
        if chunk is None or vec is None:
            continue
        for other, cos in store.vector_search(chunk.namespace, vec, embedder.signature, 6):
            if other == cid or other in hidden or cos < DEDUP_THRESHOLD:
                continue
            o = by_id.get(other)
            if o is None or (o.created_at, o.id) < (chunk.created_at, chunk.id):
                continue  # only merge forward: the earlier memory is the keeper
            if not same_specifics(chunk.body, o.body):
                continue  # reads alike, but another day / amount / person
            for source, tags in store.source_rows(other):
                store.merge_source(cid, source, tags)
            store.set_status([other], "hidden")
            store.set_map_fields(other, superseded_by=cid)  # forgetting cid takes the copy too
            hidden_ids["merged"].append(other)
            hidden.add(other)
            counts["merged"] += 1
            keep("merged", other)
        if i % 200 == 0:
            note("duplicates", i, len(ids))

    # 4. The map pass over everything not yet mapped.
    todo = [] if halted() else store.active_ids(unenriched=True)
    store.enqueue(todo)
    log: list = []
    total = drain(store, embedder, zone=zone, complete=complete, log=log, workers=workers,
                  progress=lambda t: note("map", t.get("enriched", 0) + t.get("hidden", 0), len(todo)),
                  should_stop=halted) if todo else {}
    counts["enriched"] += total.get("enriched", 0)
    counts["failed"] += total.get("failed", 0)
    for kind, cid in log:
        counts[kind] += 1
        keep(kind, cid)
        if kind == "hidden_trivial":
            hidden_ids["hidden_trivial"].append(cid)

    report = {"started_at": started, "finished_at": time.time(), "backup": backup_path,
              "counts": counts, "examples": examples, "hidden_ids": hidden_ids,
              "stopped": stopped["flag"]}
    path = report_path(store)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(report, indent=1), encoding="utf-8")
    tmp.replace(path)
    store.kv_set("__cleanup__", "progress", "")
    store.kv_set("__cleanup__", "stop", "")
    if progress:
        progress({"step": "done", "done": 1, "total": 1, "started_at": started})
    return report


def restore_hidden(store, ids) -> int:
    ids = [i for i in ids or [] if isinstance(i, str)]
    store.set_status(ids, "active")
    return len(ids)


def load_report(store) -> Optional[dict]:
    try:
        return json.loads(report_path(store).read_text(encoding="utf-8"))
    except Exception:
        return None
