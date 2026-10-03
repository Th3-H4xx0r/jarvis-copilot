"""Harness graphs: the shape, and the one validator phone, web and server share.

A harness is ``{id, name, icon, nodes:[…], edges:[…]}``. Node types: message
(start, exactly one), answer (a model answers while the user waits), route
(picks an outgoing edge by label), background (a non-blocking model job),
review (checks the answer just given). Edge ``when``: always · handoff ·
label:<name> · default · slow:<seconds> · tools:<count>.
"""
from __future__ import annotations

import re

NODE_TYPES = ("message", "answer", "route", "background", "review")
TOOLS_PRESETS = ("lean", "all", "none")
DELIVER_BACKGROUND = ("speak_or_notify", "post", "notify")
DELIVER_REVIEW = ("post_if_changed", "post")
ROUTE_MATCHES = ("keywords", "regex", "surface", "has_attachment")
# Wires that start a node after the answer instead of while the user waits.
AFTER_KINDS = ("handoff", "slow", "tools")
_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_MAX_NODES = 24


def parse_when(when):
    w = str(when or "always").strip()
    if w in ("always", "handoff", "default"):
        return (w, None)
    kind, _, value = w.partition(":")
    value = value.strip()
    if kind == "label" and value:
        return ("label", value)
    if kind in ("slow", "tools") and value.isdigit() and int(value) > 0:
        return (kind, value)
    raise ValueError(f"Unknown wire condition {w!r}.")


def _err(errors, message, node=None, edge=None):
    errors.append({"node": node, "edge": edge, "message": message})


def _tools_ok(value):
    if isinstance(value, str):
        return value in TOOLS_PRESETS
    return isinstance(value, list) and all(isinstance(t, str) and t for t in value)


def _num(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def _clean_node(raw, errors):
    nid = str(raw.get("id") or "").strip()
    ntype = str(raw.get("type") or "").strip()
    node = {"id": nid, "type": ntype, "x": _num(raw.get("x")), "y": _num(raw.get("y"))}
    if not _ID_RE.match(nid):
        _err(errors, "Each node needs a short id (letters, numbers, - or _).", node=nid or None)
    if ntype not in NODE_TYPES:
        _err(errors, f"Unknown node type {ntype!r}.", node=nid)
        return node
    for key in ("label", "instructions"):
        if isinstance(raw.get(key), str) and raw[key].strip():
            node[key] = raw[key].strip()[:4000]
    if ntype in ("answer", "background", "review"):
        model = str(raw.get("model") or "").strip()
        if not model:
            _err(errors, "Pick a model for this node.", node=nid)
        node["model"] = model
    if ntype in ("answer", "background"):
        tools = raw.get("tools", "lean")
        if not _tools_ok(tools):
            _err(errors, "tools must be lean, all, none or a list of toolsets.", node=nid)
        node["tools"] = tools
    if ntype == "answer":
        if raw.get("max_steps") not in (None, ""):
            try:
                node["max_steps"] = max(1, int(raw["max_steps"]))
            except (TypeError, ValueError):
                _err(errors, "max_steps must be a number.", node=nid)
        if str(raw.get("fallback_model") or "").strip():
            node["fallback_model"] = str(raw["fallback_model"]).strip()
    if ntype == "background":
        deliver = raw.get("deliver") or "speak_or_notify"
        if deliver not in DELIVER_BACKGROUND:
            _err(errors, "Unknown delivery for a Background node.", node=nid)
        node["deliver"] = deliver
    if ntype == "review":
        deliver = raw.get("deliver") or "post_if_changed"
        if deliver not in DELIVER_REVIEW:
            _err(errors, "Unknown delivery for a Review node.", node=nid)
        node["deliver"] = deliver
    if ntype == "route":
        by = raw.get("by") or "rules"
        if by not in ("rules", "model"):
            _err(errors, "A Route picks by rules or by model.", node=nid)
        node["by"] = by
        rules = []
        for r in raw.get("rules") or []:
            if not isinstance(r, dict):
                continue
            match, label, value = r.get("match"), str(r.get("label") or "").strip(), r.get("value")
            if match not in ROUTE_MATCHES or not label:
                _err(errors, "Each rule needs a match type and a label.", node=nid)
                continue
            if match == "regex":
                try:
                    re.compile(str(value or ""))
                except re.error:
                    _err(errors, "That regex does not compile.", node=nid)
                    continue
            rules.append({"match": match, "value": value, "label": label})
        node["rules"] = rules
        if by == "model":
            model = str(raw.get("model") or "").strip()
            if not model:
                _err(errors, "A model Route needs a model to label messages.", node=nid)
            node["model"] = model
        node["labels"] = [str(l).strip() for l in (raw.get("labels") or []) if str(l).strip()]
    return node


def validate_harness(doc):
    """Return ``(clean_doc, [])`` or ``(None, errors)``; errors are
    ``{"node": id|None, "edge": index|None, "message": str}``."""
    errors: list = []
    if not isinstance(doc, dict):
        return None, [{"node": None, "edge": None, "message": "A harness must be an object."}]
    hid = str(doc.get("id") or "").strip()
    if not _ID_RE.match(hid):
        _err(errors, "The harness id must be letters, numbers, - or _.")
    raw_nodes = [n for n in (doc.get("nodes") or []) if isinstance(n, dict)]
    if len(raw_nodes) > _MAX_NODES:
        _err(errors, f"A harness can have at most {_MAX_NODES} nodes.")
    nodes = [_clean_node(n, errors) for n in raw_nodes[:_MAX_NODES]]
    by_id = {}
    for n in nodes:
        if n["id"] in by_id:
            _err(errors, "Two nodes share an id.", node=n["id"])
        by_id[n["id"]] = n
    starts = [n for n in nodes if n["type"] == "message"]
    if len(starts) != 1:
        _err(errors, "A harness needs exactly one Message node (the start).")

    edges, out, incoming = [], {nid: [] for nid in by_id}, {nid: set() for nid in by_id}
    for i, e in enumerate(doc.get("edges") or []):
        if not isinstance(e, dict):
            continue
        src, dst = str(e.get("from") or ""), str(e.get("to") or "")
        if src not in by_id or dst not in by_id:
            _err(errors, "This wire points at a node that does not exist.", edge=i)
            continue
        try:
            kind, value = parse_when(e.get("when"))
        except ValueError as exc:
            _err(errors, str(exc), edge=i)
            continue
        st, dt = by_id[src]["type"], by_id[dst]["type"]
        if kind == "handoff" and (st != "answer" or dt != "background"):
            _err(errors, "A hand-off wire goes from an Answer node to a Background node.", edge=i)
        if kind in ("label", "default") and st != "route":
            _err(errors, "Only Route nodes have labelled wires.", edge=i)
        if st == "route" and kind not in ("label", "default"):
            _err(errors, "Wires out of a Route need a label (or default).", edge=i)
        if kind in ("slow", "tools") and (st != "answer" or dt not in ("background", "review")):
            _err(errors, "slow/tools wires go from an Answer to a Background or Review node.", edge=i)
        edge = {"from": src, "to": dst, "when": kind if value is None else f"{kind}:{value}"}
        edges.append(edge)
        out[src].append(edge)
        incoming[dst].add(kind)

    for n in nodes:
        if n["type"] == "route" and "default" not in [e["when"] for e in out.get(n["id"], [])]:
            _err(errors, "A Route needs one default wire.", node=n["id"])

    state = {}

    def _cyclic(nid):
        state[nid] = 1
        for e in out.get(nid, []):
            if state.get(e["to"]) == 1 or (state.get(e["to"]) is None and _cyclic(e["to"])):
                return True
        state[nid] = 2
        return False

    looped = any(state.get(nid) is None and _cyclic(nid) for nid in list(by_id))
    if looped:
        _err(errors, "The wires make a loop; a harness must flow one way.")

    if len(starts) == 1 and not looped:
        seen = set()

        def _walk(nid, answered):
            seen.add(nid)
            ntype = by_id[nid]["type"]
            after_target = bool(incoming.get(nid, set()) & set(AFTER_KINDS))
            if ntype in ("background", "review") and not answered:
                _err(errors, "This path reaches a background step before any Answer node.", node=nid)
            if ntype == "answer" and answered and not after_target:
                _err(errors, "Only one Answer node can run while you wait on a path.", node=nid)
            if ntype in ("message", "route") and not out.get(nid):
                _err(errors, "This step leads nowhere; wire it to an Answer node.", node=nid)
            for e in out.get(nid, []):
                _walk(e["to"], answered or ntype == "answer")

        _walk(starts[0]["id"], False)
        for nid in by_id:
            if nid not in seen:
                _err(errors, "This node is not connected to the Message node.", node=nid)

    clean = {"id": hid, "name": str(doc.get("name") or "").strip() or hid,
             "icon": str(doc.get("icon") or "")[:4], "nodes": nodes, "edges": edges}
    return (None if errors else clean), errors
