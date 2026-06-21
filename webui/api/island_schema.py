"""Validator for Dynamic Island design layout-trees. Pure + dependency-free.

A *design* is the declarative layout tree the iOS widget renders (see
``docs/superpowers/specs/2026-06-19-dynamic-island-designs-design.md``). This
module validates a design dict BEFORE it is stored, returning a list of
human-readable error strings (empty list == valid). It never mutates its input
and never raises on bad data — callers decide what to do with the errors.

Kept intentionally framework-free so it can be imported from the webui store,
the routes, or a test with no side effects.
"""
from __future__ import annotations

import re
from typing import Any

# Defensive bounds (mirrored by the Swift renderer's clamps). A design past
# these is rejected at author time rather than truncated silently on-device.
# Generous, not a layout limit — the expanded island + lock screen size to their
# content, so a rich design can fill the full available height. These only guard
# against pathological/cyclic trees.
MAX_DEPTH = 12
MAX_NODES = 160

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_HEX_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")

CONTAINER_TYPES = {"hstack", "vstack", "zstack", "grid", "list", "spacer", "regions"}
LEAF_TYPES = {
    "text", "titleSubtitle", "stat", "symbol", "symbolValue", "image", "dot",
    "badge", "progress", "segbar", "gauge", "timer", "timeProgress", "keyValue",
    "sparkline", "iconStrip", "waveform", "divider", "accent",
}
NODE_TYPES = CONTAINER_TYPES | LEAF_TYPES

# expanded is REQUIRED; the rest are optional projections.
PRESENTATIONS = {
    "expanded", "lockScreen", "compactLeading", "compactTrailing", "minimal",
}
REQUIRED_PRESENTATIONS = {"expanded"}

# A {"src": ...} binding must name a source in one of these namespaces. Trailing
# dot = a whole namespace of arbitrary keys (e.g. ``jarvis.deployPct``).
_SOURCE_KEYS = {
    "time.now", "device.online", "battery.level", "battery.state",
    "location.place", "calendar.next", "health.heartRate", "health.steps",
    "coding.usage5", "coding.usageWeek", "coding.fleet",
}
_SOURCE_NAMESPACES = ("jarvis.", "weather.", "coding.", "health.", "calendar.",
                      "device.", "battery.", "location.", "time.")

_CONDITION_OPS = {"and", "or", "not", "eq", "ne", "gt", "lt", "exists", "between",
                  "after", "before"}

# On-device clock binding kinds (computed from the device clock at render time —
# update OFFLINE with no server push). See _validate_clock + the iOS renderer's
# jcResolveClock.
_CLOCK_KINDS = {"phase", "fraction", "remaining", "elapsed", "index"}

# Per-leaf required value-bearing props. Each maps a prop name -> "value" (a
# scalar/binding ValueRef) or "array" (a list-or-binding). Optional props are
# validated only if present (see _OPTIONAL_VALUE_PROPS).
_REQUIRED_PROPS: dict[str, dict[str, str]] = {
    "text": {"value": "value"},
    "titleSubtitle": {"title": "value", "subtitle": "value"},
    "stat": {"value": "value"},
    "symbol": {"name": "value"},
    "symbolValue": {"symbol": "value", "value": "value"},
    "image": {"source": "value"},
    "dot": {"color": "value"},
    "badge": {"text": "value"},
    "progress": {"value": "value"},
    "segbar": {"segments": "array"},
    "timer": {"to": "value"},
    "timeProgress": {"from": "value", "to": "value"},
    "sparkline": {"points": "array"},
    "iconStrip": {"items": "array"},
}
_OPTIONAL_VALUE_PROPS: dict[str, dict[str, str]] = {
    "stat": {"unit": "value", "caption": "value"},
    # image.source may be an SF Symbol name, the reserved "orb", or an http(s)
    # URL (pre-downloaded to the App Group cache and rendered offline on-device);
    # fallback is an SF Symbol shown until a remote image is cached.
    "image": {"fallback": "value"},
    # timer.format: "relative" → "5 days, 18 hr" (best for multi-day); omit/other
    # → clock HH:MM:SS. Both tick on-device offline.
    "timer": {"format": "value"},
    "badge": {"color": "value"},
    "progress": {"tint": "value"},
    # segbar tip position: explicit `progress` (0–1) wins, else elapsed fraction of
    # `from`→`to` dates (computed on-device at each update). `tip` itself (an
    # object/string) is validated separately by _validate_tip.
    "segbar": {"progress": "value", "from": "value", "to": "value"},
    "symbol": {"effect": "value"},
    "waveform": {"active": "value"},
    "accent": {"color": "value"},
}


def is_valid(design: Any) -> bool:
    return not validate_design(design)


def validate_design(design: Any) -> list[str]:
    """Return a list of error strings; empty means the design is valid."""
    errors: list[str] = []
    if not isinstance(design, dict):
        return ["design must be an object"]

    schema = design.get("schema", 1)
    if not isinstance(schema, int) or schema < 1:
        errors.append("schema must be a positive integer")

    did = design.get("id")
    if not isinstance(did, str) or not _ID_RE.match(did):
        errors.append("id must be a lowercase slug [a-z0-9_-], 1-64 chars")

    ver = design.get("version", 1)
    if not isinstance(ver, int) or ver < 0:
        errors.append("version must be a non-negative integer")

    name = design.get("name")
    if not isinstance(name, str) or not name.strip():
        errors.append("name must be a non-empty string")

    tint = design.get("tint")
    if tint is not None and not (isinstance(tint, str) and _is_color_literal(tint)):
        errors.append("tint must be a hex (#RGB/#RRGGBB/#RRGGBBAA) or named color")

    pres = design.get("presentations")
    if not isinstance(pres, dict):
        errors.append("presentations must be an object")
        return errors
    for key in pres:
        if key not in PRESENTATIONS:
            errors.append(f"presentations.{key}: unknown presentation")
    for req in REQUIRED_PRESENTATIONS:
        if req not in pres:
            errors.append(f"presentations.{req} is required")
    counter = [0]  # mutable node count shared across all presentations
    for key, node in pres.items():
        if key not in PRESENTATIONS:
            continue
        _validate_node(node, f"presentations.{key}", errors, counter, depth=1,
                       in_row=False)
    if counter[0] > MAX_NODES:
        errors.append(f"too many nodes ({counter[0]} > {MAX_NODES})")
    _validate_timeline(design.get("timeline"), errors)
    _validate_notifications(design.get("notifications"), errors)
    return errors


def _validate_timeline(tl, errors) -> None:
    """Optional offline keyframe timeline: [{at: epoch seconds, data: {...}}]."""
    if tl is None:
        return
    if not isinstance(tl, list):
        errors.append("timeline must be a list")
        return
    for i, kf in enumerate(tl):
        if not isinstance(kf, dict):
            errors.append(f"timeline[{i}] must be an object")
            continue
        if not isinstance(kf.get("at"), (int, float)):
            errors.append(f"timeline[{i}].at must be epoch seconds (number)")
        if not isinstance(kf.get("data"), dict):
            errors.append(f"timeline[{i}].data must be an object")


def _validate_notifications(ns, errors) -> None:
    """Optional pre-scheduled local notifications: [{at, title, body}]."""
    if ns is None:
        return
    if not isinstance(ns, list):
        errors.append("notifications must be a list")
        return
    for i, n in enumerate(ns):
        if not isinstance(n, dict):
            errors.append(f"notifications[{i}] must be an object")
            continue
        if not isinstance(n.get("at"), (int, float)):
            errors.append(f"notifications[{i}].at must be epoch seconds (number)")
        if not isinstance(n.get("title"), str) or not n["title"].strip():
            errors.append(f"notifications[{i}].title must be a non-empty string")
        if "body" in n and not isinstance(n["body"], str):
            errors.append(f"notifications[{i}].body must be a string")


def validate_condition(expr: Any, path: str = "condition") -> list[str]:
    """Validate a condition expression (used by `when` and auto-rules)."""
    errors: list[str] = []
    _validate_condition(expr, path, errors)
    return errors


# ── internals ────────────────────────────────────────────────────────────────

def _validate_node(node, path, errors, counter, depth, in_row):
    if depth > MAX_DEPTH:
        errors.append(f"{path}: nesting too deep (> {MAX_DEPTH})")
        return
    if not isinstance(node, dict):
        errors.append(f"{path}: node must be an object")
        return
    counter[0] += 1
    ntype = node.get("type")
    if ntype not in NODE_TYPES:
        errors.append(f"{path}: unknown node type {ntype!r}")
        return
    if "when" in node:
        _validate_condition(node["when"], f"{path}.when", errors)

    if ntype in ("hstack", "vstack", "zstack", "grid"):
        children = node.get("children", [])
        if not isinstance(children, list):
            errors.append(f"{path}.children must be a list")
        else:
            for i, ch in enumerate(children):
                _validate_node(ch, f"{path}.children[{i}]", errors, counter,
                               depth + 1, in_row)
        if ntype == "grid":
            cols = node.get("columns")
            if not isinstance(cols, int) or cols < 1:
                errors.append(f"{path}.columns must be a positive integer")
    elif ntype == "regions":
        if path != "presentations.expanded":
            errors.append(f"{path}: 'regions' is only allowed at the top of "
                          f"presentations.expanded")
        for slot in ("leading", "trailing", "center", "bottom"):
            if slot in node:
                _validate_node(node[slot], f"{path}.{slot}", errors, counter,
                               depth + 1, in_row)
    elif ntype == "list":
        _validate_value(node.get("data"), f"{path}.data", errors,
                        allow_array=True, in_row=in_row, required=True)
        row = node.get("row")
        if row is None:
            errors.append(f"{path}.row is required")
        else:
            # Inside a row template, {"$row":"field"} bindings become legal.
            _validate_node(row, f"{path}.row", errors, counter, depth + 1,
                           in_row=True)
        cols = node.get("columns")
        if cols is not None and (not isinstance(cols, int) or cols < 1):
            errors.append(f"{path}.columns must be a positive integer")
    elif ntype == "spacer" or ntype in ("divider",):
        pass  # no required props
    else:
        # leaf element
        for prop, kind in _REQUIRED_PROPS.get(ntype, {}).items():
            if prop not in node:
                errors.append(f"{path}.{prop} is required for {ntype}")
            else:
                _validate_value(node[prop], f"{path}.{prop}", errors,
                                allow_array=(kind == "array"), in_row=in_row)
        for prop, kind in _OPTIONAL_VALUE_PROPS.get(ntype, {}).items():
            if prop in node:
                _validate_value(node[prop], f"{path}.{prop}", errors,
                                allow_array=(kind == "array"), in_row=in_row)
        if ntype == "gauge":
            rings = node.get("rings")
            if not isinstance(rings, list) or not rings:
                errors.append(f"{path}.rings must be a non-empty list")
            else:
                for i, r in enumerate(rings):
                    if not isinstance(r, dict) or "value" not in r:
                        errors.append(f"{path}.rings[{i}] must have a value")
                    else:
                        _validate_value(r.get("value"), f"{path}.rings[{i}].value",
                                        errors, in_row=in_row)
        elif ntype == "keyValue":
            pairs = node.get("pairs")
            if not isinstance(pairs, list) or not pairs:
                errors.append(f"{path}.pairs must be a non-empty list")
            else:
                for i, p in enumerate(pairs):
                    if not isinstance(p, dict) or "value" not in p:
                        errors.append(f"{path}.pairs[{i}] must have a value")
                    else:
                        _validate_value(p.get("value"), f"{path}.pairs[{i}].value",
                                        errors, in_row=in_row)
        if ntype in ("progress", "segbar") and "tip" in node:
            _validate_tip(node["tip"], f"{path}.tip", errors, in_row=in_row)


def _validate_tip(tip, path, errors, *, in_row=False):
    """A tip indicator is an SF Symbol name (string) or an object
    {symbol, color?, size?, rotation?}. `symbol`/`color` may be bindings;
    `size`/`rotation` are literal numbers (the renderer does not resolve
    bindings for them)."""
    if isinstance(tip, str):
        if not tip.strip():
            errors.append(f"{path}: symbol name must be non-empty")
        return
    if not isinstance(tip, dict):
        errors.append(f"{path} must be a symbol name (string) or an object")
        return
    if "symbol" not in tip:
        errors.append(f"{path}.symbol is required")
    else:
        _validate_value(tip["symbol"], f"{path}.symbol", errors, in_row=in_row)
    if "color" in tip:
        _validate_value(tip["color"], f"{path}.color", errors, in_row=in_row)
    for key in ("size", "rotation"):
        if key in tip and not isinstance(tip[key], (int, float)):
            errors.append(f"{path}.{key} must be a number")


def _validate_value(v, path, errors, allow_array=False, in_row=False,
                    required=False):
    """A ValueRef: a scalar literal, a binding dict, or (if allow_array) a list
    or array-binding."""
    if v is None:
        if required:
            errors.append(f"{path} is required")
        return
    if isinstance(v, (str, int, float, bool)):
        if allow_array:
            errors.append(f"{path}: expected a list or array binding, not a scalar")
        return  # literal scalar
    if isinstance(v, list):
        if not allow_array:
            errors.append(f"{path}: a list is not allowed here")
        return
    if isinstance(v, dict):
        if "clock" in v:
            _validate_clock(v, path, errors)
            return
        keys = {"$", "$row", "src"} & set(v.keys())
        if len(keys) != 1:
            errors.append(f"{path}: binding must have exactly one of $, $row, src, clock")
            return
        key = next(iter(keys))
        ref = v[key]
        if not isinstance(ref, str) or not ref:
            errors.append(f"{path}.{key} must be a non-empty string")
        elif key == "$row" and not in_row:
            errors.append(f"{path}: $row binding only valid inside a list row")
        elif key == "src" and not _is_known_source(ref):
            errors.append(f"{path}.src: unknown source {ref!r}")
        if "fmt" in v and not isinstance(v["fmt"], str):
            errors.append(f"{path}.fmt must be a string")
        if "map" in v and not isinstance(v["map"], dict):
            errors.append(f"{path}.map must be an object")
        return
    errors.append(f"{path}: invalid value")


def _validate_timestamp(v, path, errors):
    """A clock timestamp: an epoch number, an ISO/epoch STRING, or a binding that
    resolves to one. The device parses these with jcParseDate and never errors, so
    rejecting wrong TYPES here (a list, a bool, a nested object) is the only place a
    typo is caught — otherwise it silently fail-opens / renders empty."""
    if isinstance(v, bool):
        errors.append(f"{path} must be an epoch number or ISO date string, not a bool")
    elif isinstance(v, (int, float)):
        return
    elif isinstance(v, str):
        if not v.strip():
            errors.append(f"{path}: empty timestamp")
    elif isinstance(v, dict):
        _validate_value(v, path, errors)  # a $/src binding resolving to a timestamp
    else:
        errors.append(f"{path} must be an epoch number, ISO date string, or binding")


def _validate_clock(v, path, errors):
    """An on-device clock binding: {"clock": <kind>, …} computed from Date() at
    render time (updates OFFLINE). `at`/`from`/`to`/`keys[].at` are epoch seconds or
    ISO strings (NOT segment ordinals — they are absolute times)."""
    kind = v.get("clock")
    if kind not in _CLOCK_KINDS:
        errors.append(f"{path}.clock: unknown kind {kind!r} (expected one of "
                      f"{sorted(_CLOCK_KINDS)})")
        return
    if kind in ("phase", "index"):
        keys = v.get("keys")
        if not isinstance(keys, list) or not keys:
            errors.append(f"{path}.keys must be a non-empty list")
        elif kind == "phase":
            for i, k in enumerate(keys):
                if not isinstance(k, dict) or "at" not in k or "value" not in k:
                    errors.append(f"{path}.keys[{i}] must have 'at' and 'value'")
                else:
                    _validate_timestamp(k["at"], f"{path}.keys[{i}].at", errors)
        else:  # index: keys are bare timestamps
            for i, k in enumerate(keys):
                _validate_timestamp(k, f"{path}.keys[{i}]", errors)
    elif kind == "fraction":
        for req in ("from", "to"):
            if req not in v:
                errors.append(f"{path}: clock 'fraction' needs '{req}'")
            else:
                _validate_timestamp(v[req], f"{path}.{req}", errors)
    elif kind == "remaining":
        if "to" not in v:
            errors.append(f"{path}: clock 'remaining' needs 'to'")
        else:
            _validate_timestamp(v["to"], f"{path}.to", errors)
    elif kind == "elapsed":
        if "from" not in v:
            errors.append(f"{path}: clock 'elapsed' needs 'from'")
        else:
            _validate_timestamp(v["from"], f"{path}.from", errors)
    if "fmt" in v and not isinstance(v["fmt"], str):
        errors.append(f"{path}.fmt must be a string")
    if "map" in v and not isinstance(v["map"], dict):
        errors.append(f"{path}.map must be an object")


def _validate_condition(expr, path, errors, depth=0):
    if depth > MAX_DEPTH:
        errors.append(f"{path}: condition nested too deep")
        return
    if not isinstance(expr, dict):
        errors.append(f"{path}: condition must be an object")
        return
    op = expr.get("op")
    if op not in _CONDITION_OPS:
        errors.append(f"{path}: unknown condition op {op!r}")
        return
    if op in ("and", "or"):
        items = expr.get("items")
        if not isinstance(items, list) or not items:
            errors.append(f"{path}.items must be a non-empty list")
        else:
            for i, it in enumerate(items):
                _validate_condition(it, f"{path}.items[{i}]", errors, depth + 1)
    elif op == "not":
        _validate_condition(expr.get("item"), f"{path}.item", errors, depth + 1)
    elif op == "exists":
        _validate_value(expr.get("a"), f"{path}.a", errors, required=True)
    elif op == "between":
        _validate_value(expr.get("a"), f"{path}.a", errors, required=True)
        if "lo" not in expr or "hi" not in expr:
            errors.append(f"{path}: between needs lo and hi")
    elif op in ("after", "before"):
        # time condition: operand is the device clock (now) vs the `at` timestamp.
        if "at" not in expr:
            errors.append(f"{path}.at is required")
        else:
            _validate_timestamp(expr["at"], f"{path}.at", errors)
    else:  # eq/ne/gt/lt
        _validate_value(expr.get("a"), f"{path}.a", errors, required=True)
        _validate_value(expr.get("b"), f"{path}.b", errors, required=True)


def _is_known_source(ref: str) -> bool:
    return ref in _SOURCE_KEYS or ref.startswith(_SOURCE_NAMESPACES)


def _is_color_literal(s: str) -> bool:
    # hex, or a named system color the renderer maps (green/red/blue/etc).
    if _HEX_RE.match(s):
        return True
    return s.lower() in {
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue",
        "indigo", "purple", "pink", "brown", "gray", "grey", "white", "black",
        "primary", "secondary", "accent", "clear",
    }
