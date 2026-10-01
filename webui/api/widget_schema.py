"""Validator for Home Screen / Lock Screen widget designs. Pure + dependency-free.

A widget design is the same declarative layout tree as a Dynamic Island design
(``island_schema``), keyed by widget size instead of island region::

    {schema: 1, id, version?, name, icon?, tint?,
     presentations: {small|medium|large|extraLarge|circular|rectangular|inline: node},
     builder?: <the app's block-builder layout, stored as-is>}

Node, value and condition checks are island_schema's, run with ``WIDGET_RULES``:
the island's node types minus ``regions`` (an island-only root) plus ``chart``,
``model``, ``button`` and ``toggle``. Data bindings (``{"src": k}`` / ``{"$": k}``)
read the flat snapshot the phone publishes, so any ``area.key`` is allowed; a key
the phone's posted catalog doesn't list is a WARNING (it renders "—" until
published), never an error.

``validate_design`` returns ``(errors, warnings)`` and never raises or mutates.
"""
from __future__ import annotations

import json
import math

import re
from dataclasses import replace
from typing import Any, Iterable

from api.island_schema import (
    MAX_NODES,
    NODE_TYPES as ISLAND_NODE_TYPES,
    NodeRules,
    _ID_RE,
    _OPTIONAL_VALUE_PROPS,
    _REQUIRED_PROPS,
    _is_color_literal,
    validate_tree,
)

SIZES = ("small", "medium", "large", "extraLarge", "circular", "rectangular", "inline")
# Wearables whose 3D model the app renders to widgets/models/<device>.png.
MODEL_DEVICES = ("ring", "x5ring", "glasses", "bottle", "scale", "esp32", "pod")
CHART_STYLES = ("line", "bar", "area")

WIDGET_NODE_TYPES = frozenset(
    (set(ISLAND_NODE_TYPES) - {"regions"}) | {"chart", "model", "button", "toggle"})

# A data key: area + one or more dotted names, e.g. health.steps, x5ring.battery.
_DATA_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$")

_WIDGET_REQUIRED = {**_REQUIRED_PROPS, "chart": {"series": "array"}}
_WIDGET_OPTIONAL = {
    **_OPTIONAL_VALUE_PROPS,
    "chart": {"color": "value", "min": "value", "max": "value"},
    "button": {"label": "value", "symbol": "value"},
    "toggle": {"label": "value"},
}


def _check_widget_leaf(ntype, node, path, errors, in_row):
    if ntype == "chart":
        style = node.get("style")
        # Any node may carry a style OBJECT; a string here is the chart kind.
        if style is not None and not isinstance(style, dict) and style not in CHART_STYLES:
            errors.append(f"{path}.style must be one of {', '.join(CHART_STYLES)}")
        for prop in ("min", "max"):  # lists and bindings are checked as values
            if isinstance(node.get(prop), (bool, str)):
                errors.append(f"{path}.{prop} must be a number or a binding")
    elif ntype == "model":
        device = node.get("device")
        if "device" not in node:
            errors.append(f"{path}.device is required for model")
        elif device not in MODEL_DEVICES:
            errors.append(f"{path}.device must be one of {', '.join(MODEL_DEVICES)}")
    elif ntype in ("button", "toggle"):
        button = node.get("button")
        if "button" not in node:
            errors.append(f"{path}.button is required for {ntype}")
        elif not isinstance(button, str) or not button.strip():
            errors.append(f"{path}.button must be a Control Center button id (string)")


def _check_data_key(kind, ref, path, errors):
    if kind == "src" and not _DATA_KEY_RE.match(ref):
        errors.append(f"{path}.src: {ref!r} must be an area.key data key such as "
                      f"'health.steps'")


WIDGET_RULES = NodeRules(
    node_types=WIDGET_NODE_TYPES,
    required_props=_WIDGET_REQUIRED,
    optional_props=_WIDGET_OPTIONAL,
    check_binding=_check_data_key,
    check_leaf=_check_widget_leaf,
)


#: A design is a layout, not data: anything bigger is a mistake (or abuse), and the phone
#: and widget hold every design in memory.
MAX_DESIGN_BYTES = 64_000


def _non_finite(value: Any, path: str, errors: list[str]) -> None:
    """NaN / Infinity parse as JSON numbers in Python but break the phone (and are not JSON)."""
    if isinstance(value, float) and not math.isfinite(value):
        errors.append(f"{path}: numbers must be finite, not {value!r}")
    elif isinstance(value, dict):
        for k, v in value.items():
            _non_finite(v, f"{path}.{k}", errors)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            _non_finite(v, f"{path}[{i}]", errors)


def validate_design(design: Any, catalog_keys: Iterable[str] | None = None
                    ) -> tuple[list[str], list[str]]:
    """Return ``(errors, warnings)``; no errors means the design may be stored.

    ``catalog_keys`` are the data keys the phone publishes (from its posted
    catalog). None skips the check; an empty set gives one "no catalog" warning.
    """
    errors: list[str] = []
    if not isinstance(design, dict):
        return ["design must be an object"], []

    schema = design.get("schema", 1)
    if not isinstance(schema, int) or isinstance(schema, bool) or schema < 1:
        errors.append("schema must be a positive integer")
    did = design.get("id")
    if not isinstance(did, str) or not _ID_RE.match(did):
        errors.append("id must be a lowercase slug [a-z0-9_-], 1-64 chars")
    ver = design.get("version", 1)
    if not isinstance(ver, int) or isinstance(ver, bool) or ver < 0:
        errors.append("version must be a non-negative integer")
    name = design.get("name")
    if not isinstance(name, str) or not name.strip():
        errors.append("name must be a non-empty string")
    icon = design.get("icon")
    if icon is not None and not (isinstance(icon, str) and icon.strip()):
        errors.append("icon must be an SF Symbol name")
    tint = design.get("tint")
    if tint is not None and not (isinstance(tint, str) and _is_color_literal(tint)):
        errors.append("tint must be a hex (#RGB/#RRGGBB/#RRGGBBAA) or named color")

    try:
        size = len(json.dumps(design, allow_nan=True))
    except (TypeError, ValueError):
        size = 0
        errors.append("design must be plain JSON")
    if size > MAX_DESIGN_BYTES:
        errors.append(f"design is too large ({size} bytes > {MAX_DESIGN_BYTES})")
    _non_finite(design, "design", errors)

    pres = design.get("presentations")
    if not isinstance(pres, dict):
        errors.append("presentations must be an object keyed by widget size")
        return errors, []
    if not pres:
        errors.append(f"presentations needs at least one size ({', '.join(SIZES)})")

    used: list[tuple[str, str]] = []  # (path, key) of every data binding

    def check_binding(kind, ref, path, errs):
        before = len(errs)
        _check_data_key(kind, ref, path, errs)
        if len(errs) == before:
            used.append((f"{path}.{kind}", ref))

    rules = replace(WIDGET_RULES, check_binding=check_binding)
    for key, node in pres.items():
        if key not in SIZES:
            errors.append(f"presentations.{key}: unknown size (use {', '.join(SIZES)})")
            continue
        counter = [0]
        validate_tree(node, f"presentations.{key}", errors, counter, rules=rules)
        if counter[0] > MAX_NODES:
            errors.append(f"presentations.{key}: too many nodes "
                          f"({counter[0]} > {MAX_NODES})")
    return errors, _catalog_warnings(used, catalog_keys)


def _catalog_warnings(used, catalog_keys) -> list[str]:
    if catalog_keys is None or not used:
        return []
    known = set(catalog_keys)
    if not known:
        return ["no data catalog from the phone yet, so data keys weren't checked "
                "(it posts one when Jarvis opens)"]
    warnings: list[str] = []
    seen: set[str] = set()
    for path, key in used:
        if key not in known and key not in seen:
            seen.add(key)
            warnings.append(f"{path}: {key!r} isn't in the phone's data catalog; "
                            f"it shows \"—\" until the phone publishes it")
    return warnings


def validate_catalog(entries: Any) -> list[str]:
    """Check a posted data catalog: ``[{key, label, area, kind, unit?}, …]``."""
    if not isinstance(entries, list):
        return ["catalog must be a list of {key, label, area, kind, unit?}"]
    errors: list[str] = []
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            errors.append(f"catalog[{i}] must be an object")
            continue
        key = e.get("key")
        if not isinstance(key, str) or not _DATA_KEY_RE.match(key):
            errors.append(f"catalog[{i}].key must be an area.key data key")
        for field in ("label", "area", "kind"):
            if not isinstance(e.get(field), str) or not e[field].strip():
                errors.append(f"catalog[{i}].{field} must be a non-empty string")
        if e.get("unit") is not None and not isinstance(e["unit"], str):
            errors.append(f"catalog[{i}].unit must be a string")
    return errors


__all__ = ["CHART_STYLES", "MAX_DESIGN_BYTES", "MODEL_DEVICES", "SIZES", "WIDGET_NODE_TYPES", "WIDGET_RULES",
           "validate_catalog", "validate_design"]
