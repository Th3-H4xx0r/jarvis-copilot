"""The memory map as a graph: him at the center, the people, places, events,
topics and orgs his memories are about, and how often they come up together.

Weights count distinct visible memories (not hidden, not superseded) under
the filters — type, time (when it happens, else when it was said), source
family (any source backing the memory). Fix tools rename, merge, pin and
unlink; recalls list the turns that injected memories, for "why it recalled".
"""
from __future__ import annotations

import json
from typing import Dict, List, Optional

from .store import _like_prefix

TYPES = ("person", "place", "org", "event", "topic")
_VISIBLE = "IFNULL(c.status,'active') != 'hidden' AND c.valid_to IS NULL"


def _filters(namespace, types, since, source):
    where = ["c.namespace=?", _VISIBLE]
    args: list = [namespace]
    types = [t for t in (types or []) if t in TYPES]
    if types:
        where.append(f"e.type IN ({','.join('?' * len(types))})")
        args += types
    if since:
        where.append("IFNULL(c.event_start, c.created_at) >= ?")
        args.append(float(since))
    if source:
        where.append("EXISTS (SELECT 1 FROM memory_sources s WHERE s.memory_id=c.id "
                     "AND s.source LIKE ? ESCAPE '\\')")
        args.append(_like_prefix(source.rstrip(":") + ":"))
    return " AND ".join(where), args


def _node(e: dict, weight: int) -> dict:
    return {"id": e["id"], "label": e["canonical"], "type": e["type"], "weight": int(weight),
            "pinned": bool(e.get("pinned")), "event_start": e.get("event_start")}


def _edges_among(store, ids, where, args) -> List[dict]:
    if len(ids) < 2:
        return []
    q = ",".join("?" * len(ids))
    with store._lock:
        rows = store._conn.execute(
            f"SELECT a.entity_id AS a, b.entity_id AS b, COUNT(DISTINCT c.id) AS w "
            f"FROM memory_entities a JOIN memory_entities b ON a.memory_id=b.memory_id "
            f"AND a.entity_id < b.entity_id JOIN chunks c ON c.id=a.memory_id "
            f"JOIN entities e ON e.id=b.entity_id "
            f"WHERE a.entity_id IN ({q}) AND b.entity_id IN ({q}) AND {where} GROUP BY a.entity_id, b.entity_id",
            list(ids) + list(ids) + args).fetchall()
    return [{"a": r["a"], "b": r["b"], "weight": r["w"]} for r in rows]


def build(store, namespace, *, center="me", types=None, since=None, source=None, limit=40) -> dict:
    where, args = _filters(namespace, types, since, source)
    limit = max(1, min(int(limit or 40), 200))
    if center == "me":
        with store._lock:
            rows = store._conn.execute(
                f"SELECT e.id AS id, COUNT(DISTINCT c.id) AS w FROM entities e "
                f"JOIN memory_entities m ON m.entity_id=e.id JOIN chunks c ON c.id=m.memory_id "
                f"WHERE e.namespace=? AND {where} GROUP BY e.id ORDER BY e.pinned DESC, w DESC LIMIT ?",
                [namespace] + args + [limit]).fetchall()
        weights = {r["id"]: r["w"] for r in rows}
        ents = store.get_entities(list(weights))
        nodes = [_node(ents[i], w) for i, w in weights.items() if i in ents]
        edges = [{"a": "me", "b": n["id"], "weight": n["weight"]} for n in nodes]
        edges += _edges_among(store, [n["id"] for n in nodes], where, args)
        return {"center": {"id": "me", "label": "You", "type": "me"}, "nodes": nodes, "edges": edges}
    ent = store.get_entities([center]).get(center)
    if ent is None:
        raise KeyError(center)
    with store._lock:
        rows = store._conn.execute(
            f"SELECT b.entity_id AS id, COUNT(DISTINCT c.id) AS w FROM memory_entities a "
            f"JOIN memory_entities b ON a.memory_id=b.memory_id AND b.entity_id != a.entity_id "
            f"JOIN chunks c ON c.id=a.memory_id JOIN entities e ON e.id=b.entity_id "
            f"WHERE a.entity_id=? AND {where} GROUP BY b.entity_id ORDER BY w DESC LIMIT ?",
            [center] + args + [limit]).fetchall()
    weights = {r["id"]: r["w"] for r in rows}
    ents = store.get_entities(list(weights))
    nodes = [_node(ents[i], w) for i, w in weights.items() if i in ents]
    edges = _edges_among(store, [center] + [n["id"] for n in nodes], where, args)
    return {"center": {"id": center, "label": ent["canonical"], "type": ent["type"]},
            "nodes": nodes, "edges": edges}


def _entity_out(e: dict) -> dict:
    return {"id": e["id"], "type": e["type"], "label": e["canonical"], "aliases": e.get("aliases") or [],
            "pinned": bool(e.get("pinned")), "event_start": e.get("event_start"),
            "event_end": e.get("event_end"), "summary": e.get("summary") or ""}


def entity_detail(store, entity_id, limit=50) -> dict:
    ent = store.get_entities([entity_id]).get(entity_id)
    if ent is None:
        raise KeyError(entity_id)
    with store._lock:
        rows = store._conn.execute(
            "SELECT c.id AS id, m.role AS role FROM memory_entities m JOIN chunks c ON c.id=m.memory_id "
            "WHERE m.entity_id=? AND IFNULL(c.status,'active') != 'hidden' "
            "ORDER BY c.created_at DESC LIMIT ?",
            (entity_id, limit)).fetchall()
    roles = {r["id"]: r["role"] for r in rows}
    chunks = {c.id: c for c in store.get_chunks(list(roles))}
    memories = [{"id": c.id, "body": c.body, "created_at": c.created_at, "event_start": c.event_start,
                 "kind": c.kind, "source": c.source, "role": roles[c.id], "past": bool(c.valid_to)}
                for cid in roles for c in [chunks.get(cid)] if c is not None]
    neighbors = build(store, ent["namespace"], center=entity_id, limit=20)["nodes"]
    return {"entity": _entity_out(ent), "memories": memories,
            "neighbors": [{"id": n["id"], "label": n["label"], "type": n["type"], "weight": n["weight"]}
                          for n in neighbors]}


def merge(store, from_id, into_id) -> dict:
    """Fold ``from_id`` into ``into_id``: links move, names become aliases."""
    if from_id == into_id:
        raise ValueError("can't merge a node into itself")
    ents = store.get_entities([from_id, into_id])
    if len(ents) != 2:
        raise KeyError(from_id if from_id not in ents else into_id)
    src, dst = ents[from_id], ents[into_id]
    if src["type"] != dst["type"]:
        raise ValueError("only nodes of the same type can merge")
    store.merge_entities(from_id, into_id, extra_aliases=[src["canonical"]] + list(src.get("aliases") or []))
    return _entity_out(store.get_entities([into_id])[into_id])


def update_entity(store, entity_id, *, label=None, aliases=None, pinned=None) -> dict:
    ent = store.get_entities([entity_id]).get(entity_id)
    if ent is None:
        raise KeyError(entity_id)
    if label is not None:
        label = " ".join(str(label).split())
        if not label:
            raise ValueError("a name can't be empty")
        if label.lower() != ent["canonical"].lower():
            twin = store.find_entity(ent["namespace"], ent["type"], label)
            if twin and twin != entity_id:
                return merge(store, entity_id, twin)  # renaming onto an existing name merges
    store.edit_entity(entity_id, canonical=label, aliases=aliases, pinned=pinned)
    return _entity_out(store.get_entities([entity_id])[entity_id])


def unlink(store, memory_id, entity_id) -> None:
    store.unlink_entity(memory_id, entity_id)


def recalls(store, *, limit=30, session_id=None) -> List[dict]:
    out = []
    for t in store.recent_traces(500, session_id=session_id):
        hits = [h[0] for h in (t.get("trace") or {}).get("hits") or [] if h]
        if not hits:
            continue
        links = store.entities_for(hits)
        ents = list(dict.fromkeys(e for cid in hits for e, _ in links.get(cid, [])))
        out.append({"id": t["id"], "ts": t["ts"], "session_id": t.get("session_id") or "",
                    "query": t.get("query") or "", "memory_ids": hits, "entity_ids": ents,
                    "ms": (t.get("trace") or {}).get("ms")})
        if len(out) >= limit:
            break
    return out


def highlight(store, namespace, recall_id) -> dict:
    trace = store.get_trace(int(recall_id))
    if trace is None:
        raise KeyError(recall_id)
    hits = [h[0] for h in (trace.get("trace") or {}).get("hits") or [] if h]
    links = store.entities_for(hits)
    lit = list(dict.fromkeys(e for cid in hits for e, _ in links.get(cid, [])))
    where, args = _filters(namespace, None, None, None)
    with store._lock:
        q = ",".join("?" * len(lit)) or "''"
        rows = store._conn.execute(
            f"SELECT e.id AS id, COUNT(DISTINCT c.id) AS w FROM entities e JOIN memory_entities m "
            f"ON m.entity_id=e.id JOIN chunks c ON c.id=m.memory_id WHERE e.id IN ({q}) AND {where} "
            f"GROUP BY e.id", lit + args).fetchall()
    weights = {r["id"]: r["w"] for r in rows}
    ents = store.get_entities(lit)
    nodes = [_node(ents[i], weights.get(i, 0)) for i in lit if i in ents]
    edges = [{"a": "me", "b": n["id"], "weight": n["weight"]} for n in nodes]
    edges += _edges_among(store, [n["id"] for n in nodes], where, args)
    return {"center": {"id": "me", "label": "You", "type": "me"}, "nodes": nodes, "edges": edges,
            "highlight": [n["id"] for n in nodes]}
