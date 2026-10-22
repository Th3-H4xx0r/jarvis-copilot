"""The map pass: what each memory is about, when it happens, who and where.

A background loop takes new memories off the map queue in batches and asks the
memory model, once per batch, for each memory's kind and importance, when the
thing it talks about happens (relative dates resolved against when it was
said, in his time zone), the people / places / events / topics it involves and
in what role, short "role: value" slots that make it findable by role
("venue: Circuit of the Americas"), and which nearby memories it makes no
longer true. Trivial memories are hidden, superseded ones marked past —
nothing is deleted. The memory is then re-embedded with its slots.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from datetime import datetime
from typing import Callable, Dict, List, Optional

from .entities import EntityIndex
from .store import GLOBAL_NS

logger = logging.getLogger(__name__)

BATCH = 15
RELATED = 3
KINDS = {"event", "plan", "fact", "preference", "relationship", "summary"}
ENTITY_TYPES = {"person", "place", "org", "event", "topic"}

PROMPT = """You maintain the memory map of a personal assistant for one person (Pranav).
For each memory below, say what it is about so it can be found later by time, person, place or role.

Return ONLY a compact JSON array — one object per memory, each object on ONE line, no code fences,
no indentation — each with:
- "id": the memory id exactly as given
- "kind": one of event, plan, fact, preference, relationship, summary
- "importance": 1-10 (1 = trivia, 5 = useful, 9-10 = major life thing)
- "trivial": true only when it says nothing worth recalling ("The user has a father.", greetings, content-free notes)
- "event_start", "event_end": when the thing it talks about HAPPENS, as ISO 8601 local time (e.g. "2026-10-24T07:00"),
  or null when it is timeless. Resolve "tomorrow", "this weekend", "Saturday" against the memory's "said" time.
  A whole-day thing: start at 00:00, end at 23:59. Unknown end: null.
- "entities": [{{"name", "type": person|place|org|event|topic, "role", "aliases": []}}] — role is how it relates
  (venue, place, with, organizer, about, event, topic). Use a known entity's exact name when it is the same thing.
  Never list Pranav himself.
- "slots": "role: value · role: value" using roles venue, place, address, event, when, with, price, booking, topic
  (empty string when nothing fits)
- "supersedes": ids from its "related" list that this memory makes no longer true (moved, changed plans,
  cancelled); otherwise []

Now: {now}. His time zone: {zone}.
Known entities:
{known}

Memories:
{memories}
"""


def _parse(text: str) -> List[dict]:
    """The objects of the reply's JSON array — every complete one, even when
    the reply was cut off mid-array (those memories just stay queued)."""
    text = text or ""
    start = text.find("[")
    if start < 0:
        return []
    decoder = json.JSONDecoder()
    out, i = [], start + 1
    while True:
        while i < len(text) and text[i] in " \t\r\n,":
            i += 1
        if i >= len(text) or text[i] != "{":
            break
        try:
            obj, i = decoder.raw_decode(text, i)
        except ValueError:
            break
        if isinstance(obj, dict) and obj.get("id"):
            out.append(obj)
    return out


def _when(value, zone) -> Optional[float]:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        d = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=zone)
    return d.timestamp()


def _local(ts: float, zone) -> str:
    d = datetime.fromtimestamp(float(ts), zone)
    return f"{d:%a} {d.day} {d:%b %Y %H:%M %Z}"


def _related(store, embedder, chunk) -> List:
    vec = store.vector_of(chunk.id, embedder.signature)
    if vec is None:
        return []
    hits = store.vector_search(chunk.namespace, vec, embedder.signature, RELATED + 1)
    ids = [cid for cid, _ in hits if cid != chunk.id][:RELATED]
    return store.get_chunks(ids)


def enrich_batch(store, embedder, ids: List[str], *, zone,
                 complete: Optional[Callable[[str, int], str]] = None,
                 now: Optional[float] = None, log: Optional[list] = None) -> Dict[str, int]:
    """Map up to ``BATCH`` memories in one model call. Returns counts; with
    ``log``, appends ``(what, memory_id)`` for each hidden / superseded one."""
    from . import llm
    complete = complete or llm.complete
    counts = {"enriched": 0, "hidden": 0, "superseded": 0, "failed": 0}
    chunks = [c for c in store.get_chunks(list(ids)[:BATCH]) if c.status != "hidden"]
    if not chunks:
        store.dequeue(ids)
        return counts
    indexes: Dict[str, EntityIndex] = {}

    def index_for(ns):
        if ns not in indexes:
            idx = EntityIndex(store, ns)
            idx.refresh()
            idx.frozen = True  # one rebuild per batch; new names dedupe by canonical anyway
            indexes[ns] = idx
        return indexes[ns]

    related = {c.id: _related(store, embedder, c) for c in chunks}
    known: Dict[str, dict] = {}
    for c in chunks:
        for eid, _alias, _w in index_for(c.namespace).match(c.body):
            known[eid] = None
    known_rows = store.get_entities(list(known))
    lines = []
    for c in chunks:
        src = (c.source or "").split(":", 1)[0]
        lines.append(f"- id {c.id} · said {_local(c.created_at, zone)} · from {src}\n  {c.body.strip()}")
        for r in related[c.id]:
            lines.append(f"  related {r.id}: {' '.join(r.body.split())[:200]}")
    prompt = PROMPT.format(
        now=_local(now or time.time(), zone), zone=getattr(zone, "key", str(zone)),
        known="\n".join(f"- {e['type']}: {e['canonical']}" + (f" (aka {', '.join(e['aliases'])})" if e['aliases'] else "")
                        for e in known_rows.values()) or "- (none yet)",
        memories="\n".join(lines))
    try:
        reply = complete(prompt, 8000)
    except Exception as exc:  # the model being unreachable must not burn retries
        logger.warning("jarvis_memory map: model call failed (%s); will retry", exc)
        store.release([c.id for c in chunks])
        return counts
    by_id = {d["id"]: d for d in _parse(reply)}
    by_chunk = {c.id: c for c in chunks}
    to_embed: List[tuple] = []  # (chunk, text) — embedded together after the batch
    missing = [cid for cid in by_chunk if cid not in by_id]
    if missing:
        store.bump_attempts(missing)
        counts["failed"] += len(missing)
    for cid, item in by_id.items():
        c = by_chunk.get(cid)
        if c is None:
            continue
        try:
            counts_one = _apply(store, embedder, c, item, related.get(cid, []), zone,
                                index_for(c.namespace), log, to_embed)
            for k, v in counts_one.items():
                counts[k] += v
            store.dequeue([cid])
        except Exception:
            logger.warning("jarvis_memory map: could not apply %s", cid, exc_info=True)
            store.bump_attempts([cid])
            counts["failed"] += 1
    if to_embed:
        try:
            vecs = embedder.embed([text for _c, text in to_embed])
            for (c, _text), vec in zip(to_embed, vecs):
                if vec:
                    store.set_vector(c.id, c.namespace, vec, embedder.signature, embedder.dim)
        except Exception:
            logger.debug("jarvis_memory map: re-embed failed for a batch", exc_info=True)
    return counts


def _apply(store, embedder, c, item, related, zone, index, log=None, to_embed=None) -> Dict[str, int]:
    out = {"enriched": 0, "hidden": 0, "superseded": 0}
    deliberate = c.pinned or (c.source or "").startswith(("tool:memory_store", "builtin:"))
    if item.get("trivial") is True and not deliberate:  # never hide what he saved on purpose
        store.set_status([c.id], "hidden")
        store.set_map_fields(c.id, enriched_at=time.time())
        out["hidden"] = 1
        if log is not None:
            log.append(("hidden_trivial", c.id))
        return out
    kind = str(item.get("kind") or "").lower()
    try:
        importance = max(1, min(10, int(item.get("importance"))))
    except (TypeError, ValueError):
        importance = None
    start = _when(item.get("event_start"), zone)
    end = _when(item.get("event_end"), zone)
    slots = " ".join(str(item.get("slots") or "").split())[:400]
    for ent in item.get("entities") or []:
        if not isinstance(ent, dict):
            continue
        name = " ".join(str(ent.get("name") or "").split())
        etype = str(ent.get("type") or "").lower()
        if not name or etype not in ENTITY_TYPES or name.lower() in ("pranav", "the user", "user"):
            continue
        aliases = [str(a) for a in (ent.get("aliases") or []) if str(a).strip()]
        eid = index.resolve(name, etype)
        record = {"namespace": c.namespace or GLOBAL_NS, "type": etype, "aliases": aliases}
        if eid:
            existing = store.get_entities([eid]).get(eid) or {}
            record["canonical"] = existing.get("canonical") or name
        else:
            record["canonical"] = name
        if etype == "event" and start:
            record.update(event_start=start, event_end=end or start)
        eid = store.upsert_entity(record)
        store.link(c.id, eid, str(ent.get("role") or "").lower()[:30])
    offered = {r.id for r in related}
    for old in item.get("supersedes") or []:
        if old in offered and old != c.id:
            store.set_map_fields(old, valid_to=c.created_at, superseded_by=c.id)
            out["superseded"] += 1
            if log is not None:
                log.append(("superseded", old))
    fields = {"slots": slots, "enriched_at": time.time()}
    if kind in KINDS:
        fields["kind"] = kind
    if importance is not None:
        fields["importance"] = importance
    if start is not None and c.event_start is None:  # times a source set directly win
        fields["event_start"] = start
        fields["event_end"] = end
    store.set_map_fields(c.id, **fields)
    if slots:
        text = c.body + " " + slots
        if to_embed is not None:
            to_embed.append((c, text))
        else:
            try:
                vec = embedder.embed_one(text)
                if vec:
                    store.set_vector(c.id, c.namespace, vec, embedder.signature, embedder.dim)
            except Exception:
                logger.debug("jarvis_memory map: re-embed failed for %s", c.id, exc_info=True)
    out["enriched"] = 1
    return out


# ── background loop ───────────────────────────────────────────────────────
_loops: Dict[str, threading.Thread] = {}
_loops_lock = threading.Lock()


def start_loop(store, embedder, *, interval: float = 30.0, stop: Optional[threading.Event] = None) -> None:
    """One map loop per database: drain the queue, then wait ``interval``."""
    key = store.db_path
    with _loops_lock:
        if key in _loops and _loops[key].is_alive():
            return
        t = threading.Thread(target=_run, args=(store, embedder, interval, stop or threading.Event()),
                             daemon=True, name="jarvis-mem-map")
        _loops[key] = t
        t.start()


def drain(store, embedder, *, zone=None, complete=None, max_batches: Optional[int] = None,
          progress: Optional[Callable[[dict], None]] = None, log: Optional[list] = None,
          workers: int = 1, should_stop: Optional[Callable[[], bool]] = None) -> Dict[str, int]:
    """Map everything queued (or ``max_batches``), ``workers`` batches at a
    time — claims keep them apart, so the model calls overlap. A worker stops
    when a batch makes no progress (model down)."""
    from . import tz
    zone = zone or tz.user_zone()
    total = {"enriched": 0, "hidden": 0, "superseded": 0, "failed": 0, "batches": 0}
    lock = threading.Lock()

    def worker():
        while True:
            if should_stop is not None and should_stop():
                return
            with lock:
                if max_batches is not None and total["batches"] >= max_batches:
                    return
                total["batches"] += 1  # reserve the slot
            ids = store.claim(BATCH)
            if not ids:
                with lock:
                    total["batches"] -= 1
                return
            counts = enrich_batch(store, embedder, ids, zone=zone, complete=complete, log=log)
            with lock:
                for k, v in counts.items():
                    total[k] += v
                snapshot = dict(total)
            if progress:
                progress(snapshot)
            if not any(counts.values()):
                return

    if workers <= 1:
        worker()
    else:
        threads = [threading.Thread(target=worker, daemon=True, name=f"jarvis-mem-map-{i}")
                   for i in range(workers)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    if total["enriched"] or total["hidden"]:
        try:
            from . import brief
            brief.mark_dirty()
        except Exception:
            pass
    return total


def _run(store, embedder, interval, stop):
    while not stop.wait(interval):
        try:
            drain(store, embedder, max_batches=20, workers=2)
        except Exception:
            logger.warning("jarvis_memory map loop tick failed", exc_info=True)
