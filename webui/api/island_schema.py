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
    "badge", "progress", "segbar", "gauge", "timer", "keyValue", "sparkline",
    "iconStrip", "waveform", "divider", "accent",
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

_CONDITION_OPS = {"and", "or", "not", "eq", "ne", "gt", "lt", "exists", "between"}

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
    "sparkline": {"points": "array"},
    "iconStrip": {"items": "array"},
}
_OPTIONAL_VALUE_PROPS: dict[str, dict[str, str]] = {
    "stat": {"unit": "value", "caption": "value"},
    "badge": {"color": "value"},
    "progress": {"tint": "value"},
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
    return errors


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
        keys = {"$", "$row", "src"} & set(v.keys())
        if len(keys) != 1:
            errors.append(f"{path}: binding must have exactly one of $, $row, src")
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
