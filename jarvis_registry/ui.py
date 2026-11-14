"""An integration's own UI: a card for the Integrations tab and a page for its screen.

Jarvis designs it; the phone draws it. One registry document, key ``ui``, in the
integration's space holds both layout trees (the JarvisDesign node format the Dynamic
Island and widgets already use, plus page and input nodes) and the Python scripts the
UI runs::

    {"schema": 1, "version": 4,
     "presentations": {"card": NODE, "page": NODE},
     "scripts": {"load": {"code": "..."}, "add_item": {"code": "...", "confirm": "Add it?"}},
     "prompt": "what the person asked for",
     "updated_at": "2026-11-03T12:00:00Z"}

The UI never changes data itself. ``load`` builds a **state** dict the trees bind to,
and every interaction runs one named script, which decides what changes and returns
the new state (or nothing, and ``load`` runs again).

Scripts run as a subprocess with Jarvis's full access — no sandbox, by the user's
choice. Input arrives on stdin as JSON, the result is the last non-empty line of
stdout. ``jarvis_registry.ui_script`` has the one-liners a script needs.

This lives in ``jarvis_registry`` rather than ``webui/api`` because the agent tools run
in the gateway and cron processes too, where ``api.*`` is not importable. It copies the
node/value rules of ``webui/api/island_schema.py`` instead of importing them; the
island and widget validators are untouched.
"""
from __future__ import annotations

import json
import math
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from pathlib import Path
from typing import Any, Optional

UI_KEY = "ui"
SCHEMA = 1
MAX_CARD_NODES = 80
MAX_PAGE_NODES = 400
MAX_DEPTH = 16
MAX_DOC_BYTES = 256 * 1024
MAX_OUTPUT_BYTES = 2 * 1024 * 1024
LOAD_TIMEOUT = 20
ACTION_TIMEOUT = 60
CARDS_BUDGET = 20
STDERR_TAIL = 1500

PRESENTATIONS = ("card", "page")
_SLUG_RE = re.compile(r"^[a-z0-9_]+$")
_PATH_RE = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$")
_HEX_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
_NAMED_COLORS = {
    "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo",
    "purple", "pink", "brown", "gray", "grey", "white", "black", "primary",
    "secondary", "accent", "clear",
}

# ── the node set ─────────────────────────────────────────────────────────────
STACKS = {"hstack", "vstack", "zstack", "grid", "section", "hscroll"}
CONTAINERS = STACKS | {"list", "spacer"}
DISPLAY_LEAVES = {
    "text", "titleSubtitle", "stat", "symbol", "symbolValue", "image", "dot", "badge",
    "progress", "segbar", "gauge", "timer", "timeProgress", "keyValue", "sparkline",
    "iconStrip", "waveform", "divider", "accent", "chart", "model",
}
INPUTS = {"toggle", "textField", "picker", "slider", "stepper", "date"}
INTERACTIVE_LEAVES = {"row", "button"} | INPUTS
NODE_TYPES = CONTAINERS | DISPLAY_LEAVES | INTERACTIVE_LEAVES

MODEL_DEVICES = ("ring", "x5ring", "band", "glasses", "bottle", "scale", "esp32", "pod")
CHART_STYLES = ("line", "bar", "area")
BUTTON_ROLES = ("primary", "secondary", "destructive")
KEYBOARDS = ("text", "number", "email", "url")
PICKER_VARIANTS = ("segmented", "menu")
DATE_MODES = ("date", "time", "dateTime")

# prop -> "value" (scalar or binding) / "array" (list or binding). Required, then optional.
_REQUIRED: dict[str, dict[str, str]] = {
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
    "chart": {"series": "array"},
    "row": {"title": "value"},
    "button": {"label": "value"},
    "toggle": {"label": "value", "value": "value"},
    "slider": {"min": "value", "max": "value"},
}
_OPTIONAL: dict[str, dict[str, str]] = {
    "stat": {"unit": "value", "caption": "value"},
    "image": {"fallback": "value"},
    "timer": {"format": "value"},
    "badge": {"color": "value"},
    "progress": {"tint": "value"},
    "segbar": {"progress": "value", "from": "value", "to": "value"},
    "symbol": {"effect": "value"},
    "waveform": {"active": "value"},
    "accent": {"color": "value"},
    "chart": {"color": "value", "min": "value", "max": "value"},
    "gauge": {"value": "value", "label": "value"},
    "sparkline": {"tint": "value"},
    "timeProgress": {"tint": "value"},
    "section": {"title": "value", "subtitle": "value"},
    "row": {"subtitle": "value", "symbol": "value", "trailing": "value", "check": "value"},
    "button": {"symbol": "value"},
    "textField": {"placeholder": "value", "value": "value"},
    "picker": {"value": "value"},
    "slider": {"step": "value", "value": "value"},
    "stepper": {"label": "value", "min": "value", "max": "value", "step": "value",
                "value": "value"},
    "date": {"value": "value"},
}
# Nodes whose `action` must be present, and nodes that may carry one.
_ACTION_REQUIRED = {"button", "toggle"}
_ACTION_OPTIONAL = {"row", "picker", "slider", "stepper", "date"}
_CONDITION_OPS = {"and", "or", "not", "eq", "ne", "gt", "lt", "exists", "between",
                  "after", "before"}
_CLOCK_KINDS = {"phase", "fraction", "remaining", "elapsed", "index"}
# Where a custom colour belongs: charts and rings, as everywhere else in the app.
_COLOUR_OK = {"chart", "gauge", "sparkline", "progress", "segbar", "dot", "badge", "accent",
              "timeProgress"}


class UIError(Exception):
    """A UI document the server refuses. ``errors`` says why, one line each."""

    def __init__(self, errors: list[str]):
        self.errors = list(errors)
        super().__init__("; ".join(self.errors) or "invalid UI")


# ── validation ───────────────────────────────────────────────────────────────
class _Walk:
    def __init__(self, scripts: set[str]):
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.scripts = scripts
        self.actions: set[str] = set()
        self.count = 0
        self.ids: dict[str, str] = {}


def validate_ui(doc: Any) -> tuple[list[str], list[str]]:
    """Return ``(errors, warnings)``. No errors means the document may be stored.

    Never raises and never mutates ``doc``.
    """
    errors: list[str] = []
    warnings: list[str] = []
    if not isinstance(doc, dict):
        return ["the UI must be an object"], []

    schema = doc.get("schema", SCHEMA)
    if not isinstance(schema, int) or isinstance(schema, bool) or schema < 1:
        errors.append("schema must be a positive integer")
    version = doc.get("version", 0)
    if not isinstance(version, int) or isinstance(version, bool) or version < 0:
        errors.append("version must be a non-negative integer")
    if doc.get("prompt") is not None and not isinstance(doc.get("prompt"), str):
        errors.append("prompt must be text")

    try:
        size = len(json.dumps(doc, allow_nan=False).encode("utf-8"))
    except (TypeError, ValueError) as exc:
        errors.append(f"the UI must be plain JSON with finite numbers: {exc}")
        size = 0
    if size > MAX_DOC_BYTES:
        errors.append(f"the UI is too large ({size // 1024} KB > {MAX_DOC_BYTES // 1024} KB)")

    scripts = doc.get("scripts")
    names: set[str] = set()
    if not isinstance(scripts, dict):
        errors.append("scripts must be an object of {name: {code, confirm?, label?}}")
    else:
        for name, script in scripts.items():
            names.add(name)
            where = f"scripts.{name}"
            if not isinstance(name, str) or not _SLUG_RE.match(name):
                errors.append(f"{where}: a script name is lowercase letters, digits and _")
            if not isinstance(script, dict):
                errors.append(f"{where} must be an object with code")
                continue
            code = script.get("code")
            if not isinstance(code, str) or not code.strip():
                errors.append(f"{where}.code must be the script's Python source")
            else:
                try:
                    compile(code, f"{name}.py", "exec")
                except SyntaxError as exc:
                    errors.append(f"{where}.code does not compile: line {exc.lineno}: {exc.msg}")
            for key in ("confirm", "label"):
                if key in script and not (isinstance(script[key], str) and script[key].strip()):
                    errors.append(f"{where}.{key} must be non-empty text")
            extra = sorted(set(script) - {"code", "confirm", "label"})
            if extra:
                errors.append(f"{where}: unknown keys {', '.join(map(str, extra))}")
        if "load" not in scripts:
            errors.append("scripts.load is required: it builds the state the UI shows")

    pres = doc.get("presentations")
    if not isinstance(pres, dict):
        errors.append("presentations must be an object with card and/or page")
        return errors, warnings
    if not any(k in pres for k in PRESENTATIONS):
        errors.append("presentations needs a card, a page, or both")
    used: set[str] = set()
    for key, node in pres.items():
        if key not in PRESENTATIONS:
            errors.append(f"presentations.{key}: unknown presentation (card or page)")
            continue
        walk = _Walk(names)
        _node(walk, node, f"presentations.{key}", depth=1, in_row=False, grid_cols=None)
        cap = MAX_CARD_NODES if key == "card" else MAX_PAGE_NODES
        if walk.count > cap:
            walk.errors.append(f"presentations.{key}: too many nodes ({walk.count} > {cap})")
        errors.extend(walk.errors)
        warnings.extend(walk.warnings)
        used |= walk.actions
    unused = sorted(n for n in names - used - {"load"} if isinstance(n, str))
    if unused:
        warnings.append(f"scripts no control runs: {', '.join(unused)}")
    return errors, warnings


def _node(w: _Walk, node: Any, path: str, depth: int, in_row: bool,
          grid_cols: Optional[int]) -> None:
    if depth > MAX_DEPTH:
        w.errors.append(f"{path}: nested too deep (> {MAX_DEPTH})")
        return
    if not isinstance(node, dict):
        w.errors.append(f"{path}: a node must be an object")
        return
    w.count += 1
    ntype = node.get("type")
    if ntype == "regions":
        w.errors.append(f"{path}: 'regions' is for the Dynamic Island only")
        return
    if ntype not in NODE_TYPES:
        w.errors.append(f"{path}: unknown node type {ntype!r}")
        return
    if "when" in node:
        _condition(w, node["when"], f"{path}.when", in_row, 0)
    _style(w, ntype, node.get("style"), path)
    _span(w, node, path, grid_cols)

    if ntype in STACKS:
        children = node.get("children")
        if children is None and ntype != "section":
            children = []
        if not isinstance(children, list):
            w.errors.append(f"{path}.children must be a list")
            children = []
        cols = None
        if ntype == "grid":
            cols = node.get("columns")
            if not _int(cols) or not 1 <= cols <= 6:
                w.errors.append(f"{path}.columns must be a whole number from 1 to 6")
                cols = 6
        if "spacing" in node and not _number(node["spacing"]):
            w.errors.append(f"{path}.spacing must be a number")
        if ntype == "section" and "plain" in node and not isinstance(node["plain"], bool):
            w.errors.append(f"{path}.plain must be true or false")
        for prop, kind in _OPTIONAL.get(ntype, {}).items():
            if prop in node:
                _value(w, node[prop], f"{path}.{prop}", kind == "array", in_row)
        for i, child in enumerate(children):
            _node(w, child, f"{path}.children[{i}]", depth + 1, in_row, cols)
        return
    if ntype == "list":
        _value(w, node.get("data"), f"{path}.data", True, in_row, required=True)
        if node.get("row") is None:
            w.errors.append(f"{path}.row is required")
        else:
            _node(w, node["row"], f"{path}.row", depth + 1, True, None)
        if "empty" in node:
            _node(w, node["empty"], f"{path}.empty", depth + 1, in_row, None)
        for prop in ("max", "columns"):
            if prop in node and (not _int(node[prop]) or node[prop] < 1):
                w.errors.append(f"{path}.{prop} must be a positive whole number")
        return
    if ntype in ("spacer", "divider"):
        return

    for prop, kind in _REQUIRED.get(ntype, {}).items():
        if prop not in node:
            w.errors.append(f"{path}.{prop} is required for {ntype}")
        else:
            _value(w, node[prop], f"{path}.{prop}", kind == "array", in_row)
    for prop, kind in _OPTIONAL.get(ntype, {}).items():
        if prop in node:
            _value(w, node[prop], f"{path}.{prop}", kind == "array", in_row)
    _leaf(w, ntype, node, path, in_row)


def _leaf(w: _Walk, ntype: str, node: dict, path: str, in_row: bool) -> None:
    if ntype == "gauge":
        rings = node.get("rings")
        if rings is None and "value" in node:
            pass
        elif not isinstance(rings, list) or not rings:
            w.errors.append(f"{path}.rings must be a non-empty list (or give value)")
        else:
            for i, ring in enumerate(rings):
                if not isinstance(ring, dict) or "value" not in ring:
                    w.errors.append(f"{path}.rings[{i}] must have a value")
                else:
                    _value(w, ring["value"], f"{path}.rings[{i}].value", False, in_row)
    elif ntype == "keyValue":
        pairs = node.get("pairs")
        if not isinstance(pairs, list) or not pairs:
            w.errors.append(f"{path}.pairs must be a non-empty list of {{label, value}}")
        else:
            for i, pair in enumerate(pairs):
                if not isinstance(pair, dict) or "value" not in pair:
                    w.errors.append(f"{path}.pairs[{i}] must have a value")
                    continue
                _value(w, pair["value"], f"{path}.pairs[{i}].value", False, in_row)
                if "label" in pair:
                    _value(w, pair["label"], f"{path}.pairs[{i}].label", False, in_row)
    elif ntype in ("progress", "segbar") and "tip" in node:
        _tip(w, node["tip"], f"{path}.tip", in_row)
    elif ntype == "chart":
        style = node.get("style")
        if style is not None and not isinstance(style, dict) and style not in CHART_STYLES:
            w.errors.append(f"{path}.style must be one of {', '.join(CHART_STYLES)}")
        for prop in ("min", "max"):
            if isinstance(node.get(prop), (bool, str)):
                w.errors.append(f"{path}.{prop} must be a number or a binding")
        if "height" in node and not _number(node["height"]):
            w.errors.append(f"{path}.height must be a number")
        if "axes" in node and not isinstance(node["axes"], bool):
            w.errors.append(f"{path}.axes must be true or false")
    elif ntype == "model":
        if node.get("device") not in MODEL_DEVICES:
            w.errors.append(f"{path}.device must be one of {', '.join(MODEL_DEVICES)}")
    elif ntype == "text":
        if "lineLimit" in node and (not _int(node["lineLimit"]) or node["lineLimit"] < 0):
            w.errors.append(f"{path}.lineLimit must be a whole number (0 = no limit)")
        if "markdown" in node and not isinstance(node["markdown"], bool):
            w.errors.append(f"{path}.markdown must be true or false")

    if ntype in INPUTS:
        _input_id(w, node, path)
    if ntype in _ACTION_REQUIRED or ntype in _ACTION_OPTIONAL:
        _action(w, node.get("action"), f"{path}.action", required=ntype in _ACTION_REQUIRED)

    if ntype == "row":
        swipe = node.get("swipe")
        if swipe is not None:
            if not isinstance(swipe, list):
                w.errors.append(f"{path}.swipe must be a list of {{label, action, role?}}")
            else:
                for i, item in enumerate(swipe):
                    where = f"{path}.swipe[{i}]"
                    if not isinstance(item, dict):
                        w.errors.append(f"{where} must be an object {{label, action, role?}}")
                        continue
                    if "label" not in item:
                        w.errors.append(f"{where}.label is required")
                    else:
                        _value(w, item["label"], f"{where}.label", False, in_row)
                    _action(w, item.get("action"), f"{where}.action", required=True)
                    if "role" in item and item["role"] not in BUTTON_ROLES:
                        w.errors.append(f"{where}.role must be one of {', '.join(BUTTON_ROLES)}")
    elif ntype == "button":
        if "role" in node and node["role"] not in BUTTON_ROLES:
            w.errors.append(f"{path}.role must be one of {', '.join(BUTTON_ROLES)}")
        if "full" in node and not isinstance(node["full"], bool):
            w.errors.append(f"{path}.full must be true or false")
    elif ntype == "textField":
        if "submit" in node:
            _action(w, node["submit"], f"{path}.submit", required=True)
        if "keyboard" in node and node["keyboard"] not in KEYBOARDS:
            w.errors.append(f"{path}.keyboard must be one of {', '.join(KEYBOARDS)}")
    elif ntype == "picker":
        options = node.get("options")
        if options is None:
            w.errors.append(f"{path}.options is required for picker")
        elif isinstance(options, list):
            if not options:
                w.errors.append(f"{path}.options must not be empty")
            for i, opt in enumerate(options):
                if not isinstance(opt, dict) or "label" not in opt or "value" not in opt:
                    w.errors.append(f"{path}.options[{i}] must be {{label, value}}")
        else:
            _value(w, options, f"{path}.options", True, in_row)
        if "variant" in node and node["variant"] not in PICKER_VARIANTS:
            w.errors.append(f"{path}.variant must be one of {', '.join(PICKER_VARIANTS)}")
    elif ntype == "date":
        if "mode" in node and node["mode"] not in DATE_MODES:
            w.errors.append(f"{path}.mode must be one of {', '.join(DATE_MODES)}")


def _input_id(w: _Walk, node: dict, path: str) -> None:
    ident = node.get("id")
    if not isinstance(ident, str) or not _SLUG_RE.match(ident):
        w.errors.append(f"{path}.id {ident!r} must be lowercase letters, digits and _")
        return
    if ident in w.ids:
        w.errors.append(f"{path}.id {ident!r} must be unique in this tree "
                        f"(also used at {w.ids[ident]})")
    else:
        w.ids[ident] = path


def _action(w: _Walk, action: Any, path: str, required: bool) -> None:
    if action is None:
        if required:
            w.errors.append(f"{path} is required: name the script this control runs")
        return
    if not isinstance(action, str) or not action:
        w.errors.append(f"{path} must be a script name")
        return
    w.actions.add(action)
    if action not in w.scripts:
        w.errors.append(f"{path}: no script named {action!r} in scripts")


def _span(w: _Walk, node: dict, path: str, grid_cols: Optional[int]) -> None:
    if "span" not in node:
        return
    span = node["span"]
    if grid_cols is None:
        w.warnings.append(f"{path}.span only means something inside a grid")
        if not _int(span) or span < 1:
            w.errors.append(f"{path}.span must be a positive whole number")
        return
    if not _int(span) or not 1 <= span <= grid_cols:
        w.errors.append(f"{path}.span must be a whole number from 1 to {grid_cols} "
                        f"(the grid's columns)")


def _style(w: _Walk, ntype: str, style: Any, path: str) -> None:
    if style is None or (ntype == "chart" and isinstance(style, str)):
        return
    if not isinstance(style, dict):
        w.errors.append(f"{path}.style must be an object")
        return
    for key in ("size", "opacity", "padding", "width", "height", "minHeight"):
        if key in style and not _number(style[key]):
            w.errors.append(f"{path}.style.{key} must be a number")
    for key in ("color", "tint"):
        if key not in style:
            continue
        value = style[key]
        if not isinstance(value, str) or not (_HEX_RE.match(value)
                                              or value.lower() in _NAMED_COLORS):
            w.errors.append(f"{path}.style.{key} must be a hex or named colour")
        elif ntype not in _COLOUR_OK and value.lower() not in ("primary", "secondary", "accent"):
            w.warnings.append(f"{path}.style.{key}: the app uses one accent; keep custom "
                              "colours to charts and rings")


def _value(w: _Walk, v: Any, path: str, allow_array: bool, in_row: bool,
           required: bool = False) -> None:
    if v is None:
        if required:
            w.errors.append(f"{path} is required")
        return
    if isinstance(v, (str, int, float, bool)):
        if allow_array:
            w.errors.append(f"{path}: expected a list or a binding, not a single value")
        return
    if isinstance(v, list):
        if not allow_array:
            w.errors.append(f"{path}: a list is not allowed here")
        return
    if not isinstance(v, dict):
        w.errors.append(f"{path}: invalid value")
        return
    if "clock" in v:
        _clock(w, v, path, in_row)
        return
    if "src" in v:
        w.errors.append(f"{path}: src bindings are for widgets; bind to the state with "
                        "{\"$\": \"path\"}")
        return
    keys = {"$", "$row"} & set(v)
    if len(keys) != 1:
        w.errors.append(f"{path}: a binding has exactly one of $ or $row")
        return
    key = next(iter(keys))
    ref = v[key]
    if not isinstance(ref, str) or not _PATH_RE.match(ref):
        w.errors.append(f"{path}.{key} must be a dotted path like \"totals.spent\"")
    elif key == "$row" and not in_row:
        w.errors.append(f"{path}: a $row binding only works inside a list's row")
    if "fmt" in v and not isinstance(v["fmt"], str):
        w.errors.append(f"{path}.fmt must be text with {{}} where the value goes")
    if "default" in v and (isinstance(v["default"], bool)
                           or not isinstance(v["default"], (str, int, float))):
        w.errors.append(f"{path}.default must be text or a number")
    if "map" in v and not isinstance(v["map"], dict):
        w.errors.append(f"{path}.map must be an object")


def _timestamp(w: _Walk, v: Any, path: str, in_row: bool) -> None:
    if isinstance(v, bool):
        w.errors.append(f"{path} must be an epoch number or ISO date, not true/false")
    elif isinstance(v, (int, float)):
        return
    elif isinstance(v, str):
        if not v.strip():
            w.errors.append(f"{path}: empty timestamp")
    elif isinstance(v, dict):
        _value(w, v, path, False, in_row)
    else:
        w.errors.append(f"{path} must be an epoch number, ISO date or binding")


def _clock(w: _Walk, v: dict, path: str, in_row: bool) -> None:
    kind = v.get("clock")
    if kind not in _CLOCK_KINDS:
        w.errors.append(f"{path}.clock must be one of {', '.join(sorted(_CLOCK_KINDS))}")
        return
    if kind in ("phase", "index"):
        keys = v.get("keys")
        if not isinstance(keys, list) or not keys:
            w.errors.append(f"{path}.keys must be a non-empty list")
        elif kind == "phase":
            for i, k in enumerate(keys):
                if not isinstance(k, dict) or "at" not in k or "value" not in k:
                    w.errors.append(f"{path}.keys[{i}] must have at and value")
                else:
                    _timestamp(w, k["at"], f"{path}.keys[{i}].at", in_row)
        else:
            for i, k in enumerate(keys):
                _timestamp(w, k, f"{path}.keys[{i}]", in_row)
    else:
        needs = {"fraction": ("from", "to"), "remaining": ("to",), "elapsed": ("from",)}[kind]
        for req in needs:
            if req not in v:
                w.errors.append(f"{path}: clock {kind!r} needs {req!r}")
            else:
                _timestamp(w, v[req], f"{path}.{req}", in_row)


def _tip(w: _Walk, tip: Any, path: str, in_row: bool) -> None:
    if isinstance(tip, str):
        if not tip.strip():
            w.errors.append(f"{path}: symbol name must be non-empty")
        return
    if not isinstance(tip, dict):
        w.errors.append(f"{path} must be a symbol name or {{symbol, color?, size?, rotation?}}")
        return
    if "symbol" not in tip:
        w.errors.append(f"{path}.symbol is required")
    else:
        _value(w, tip["symbol"], f"{path}.symbol", False, in_row)
    if "color" in tip:
        _value(w, tip["color"], f"{path}.color", False, in_row)
    for key in ("size", "rotation"):
        if key in tip and not _number(tip[key]):
            w.errors.append(f"{path}.{key} must be a number")


def _condition(w: _Walk, expr: Any, path: str, in_row: bool, depth: int) -> None:
    if depth > MAX_DEPTH:
        w.errors.append(f"{path}: condition nested too deep")
        return
    if not isinstance(expr, dict):
        w.errors.append(f"{path}: a condition must be an object")
        return
    op = expr.get("op")
    if op not in _CONDITION_OPS:
        w.errors.append(f"{path}: unknown condition op {op!r}")
        return
    if op in ("and", "or"):
        items = expr.get("items")
        if not isinstance(items, list) or not items:
            w.errors.append(f"{path}.items must be a non-empty list")
        else:
            for i, item in enumerate(items):
                _condition(w, item, f"{path}.items[{i}]", in_row, depth + 1)
    elif op == "not":
        _condition(w, expr.get("item"), f"{path}.item", in_row, depth + 1)
    elif op in ("after", "before"):
        if "at" not in expr:
            w.errors.append(f"{path}.at is required")
        else:
            _timestamp(w, expr["at"], f"{path}.at", in_row)
    else:
        _value(w, expr.get("a"), f"{path}.a", False, in_row, required=True)
        if op == "between":
            if "lo" not in expr or "hi" not in expr:
                w.errors.append(f"{path}: between needs lo and hi")
        elif op != "exists":
            _value(w, expr.get("b"), f"{path}.b", False, in_row, required=True)


def _int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


# ── storage ──────────────────────────────────────────────────────────────────
def _registry():
    from jarvis_registry.store import shared

    return shared()


def get_ui(space_id: str) -> Optional[dict]:
    """The stored UI document, or None. Raises UnknownSpace for a space that isn't there."""
    doc = _registry().open(space_id).get(UI_KEY, default=None)
    return doc if isinstance(doc, dict) else None


def save_ui(space_id: str, doc: dict) -> dict:
    """Validate and store a UI. Returns the stored document (version bumped).

    A document without ``prompt`` keeps the one stored before it, so later edits
    keep knowing what the person first asked for.
    """
    errors, _warnings = validate_ui(doc)
    if errors:
        raise UIError(errors)
    space = _registry().open(space_id)
    if isinstance(space.get("power", default=None), dict):
        raise UIError([f"{space_id!r} is a Power integration: its UI is part of its code"])
    previous = space.get(UI_KEY, default=None)
    previous = previous if isinstance(previous, dict) else {}
    stored = json.loads(json.dumps(doc))
    stored["schema"] = stored.get("schema", SCHEMA)
    stored["version"] = max(int(previous.get("version") or 0), int(doc.get("version") or 0)) + 1
    stored["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if not stored.get("prompt") and previous.get("prompt"):
        stored["prompt"] = previous["prompt"]
    space.put(UI_KEY, stored,
              description="This integration's own UI (card + page + scripts); "
                          "change it with integration_ui_set")
    return stored


def public_definition(doc: dict) -> dict:
    """The document as the phone sees it: every script's code removed."""
    out = {k: v for k, v in doc.items() if k != "scripts"}
    scripts = doc.get("scripts") if isinstance(doc.get("scripts"), dict) else {}
    out["scripts"] = {
        name: {k: s[k] for k in ("confirm", "label") if isinstance(s, dict) and k in s}
        for name, s in scripts.items()
    }
    return out


def confirms(doc: dict) -> dict:
    """``{action: confirm text}`` for every script that asks before it runs."""
    scripts = doc.get("scripts") if isinstance(doc.get("scripts"), dict) else {}
    return {name: s["confirm"] for name, s in scripts.items()
            if isinstance(s, dict) and isinstance(s.get("confirm"), str) and s["confirm"]}


# ── running scripts ──────────────────────────────────────────────────────────
# The last state each integration's UI produced, handed to the next action as
# `state`. Per process: the web server and the gateway each keep their own.
_last_state: dict[str, dict] = {}
_state_lock = threading.Lock()


def _reset_cache() -> None:
    with _state_lock:
        _last_state.clear()


def _cached(space_id: str) -> dict:
    with _state_lock:
        return dict(_last_state.get(space_id) or {})


def _remember(space_id: str, state: dict) -> None:
    with _state_lock:
        _last_state[space_id] = state


def _repo_root() -> str:
    return str(Path(__file__).resolve().parents[1])


def _script_dir(space_id: str) -> Path:
    from jarviscopilot_constants import get_hermes_home

    return Path(get_hermes_home()) / "integration_ui" / space_id


def _event(action: str, event: Optional[dict]) -> dict:
    event = event if isinstance(event, dict) else {}
    inputs = event.get("inputs")
    row = event.get("row")
    return {
        "action": action,
        "control": event.get("control"),
        "value": event.get("value"),
        "inputs": inputs if isinstance(inputs, dict) else {},
        "row": row if isinstance(row, dict) else None,
    }


def _tail(text: str) -> str:
    text = (text or "").strip()
    return text[-STDERR_TAIL:]


def _run_script(space_id: str, name: str, code: str, payload: dict,
                timeout: float) -> dict:
    """Run one script. Returns its parsed result object, or ``{"error": ...}``."""
    folder = _script_dir(space_id)
    try:
        folder.mkdir(parents=True, exist_ok=True)
        # Never `<name>.py`: a script called `random` or `json` would shadow the
        # stdlib module for every other script (PYTHONSAFEPATH below closes that too).
        path = folder / f"script_{name}.py"
        tmp = folder / f".{name}.{os.getpid()}.{threading.get_ident()}.tmp"
        tmp.write_text(code, encoding="utf-8")
        os.replace(tmp, path)
    except OSError as exc:
        return {"error": f"could not write the {name} script: {exc}"}

    env = dict(os.environ)
    root = _repo_root()
    env["PYTHONPATH"] = root + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env["JARVIS_UI_SPACE"] = space_id
    try:
        env["JARVIS_REGISTRY_PATH"] = str(_registry().path)
    except Exception:
        pass
    env.setdefault("PYTHONIOENCODING", "utf-8")
    # The script's own folder is not put first on sys.path.
    env["PYTHONSAFEPATH"] = "1"

    try:
        proc = subprocess.Popen(
            [sys.executable, str(path)], cwd=str(folder), env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=(os.name == "posix"))
    except OSError as exc:
        return {"error": f"could not start the {name} script: {exc}"}
    out, err, over, timed_out = _collect(proc, json.dumps(payload, default=str).encode("utf-8"),
                                         timeout)
    if timed_out:
        tail = _tail(err.decode("utf-8", "replace"))
        return {"error": f"the {name} script took longer than {timeout:g} s"
                         + (f": {tail}" if tail else "")}
    if over:
        return {"error": f"the {name} script printed more than "
                         f"{MAX_OUTPUT_BYTES // (1024 * 1024)} MB"}

    stderr = _tail(err.decode("utf-8", "replace"))
    if proc.returncode != 0:
        return {"error": f"the {name} script failed (exit {proc.returncode})"
                         + (f": {stderr}" if stderr else "")}
    if len(out) > MAX_OUTPUT_BYTES:
        return {"error": f"the {name} script printed more than "
                         f"{MAX_OUTPUT_BYTES // (1024 * 1024)} MB"}
    lines = [ln for ln in out.decode("utf-8", "replace").splitlines() if ln.strip()]
    if not lines:
        return {"error": f"the {name} script printed no JSON result"
                         + (f": {stderr}" if stderr else "")}
    try:
        result = json.loads(lines[-1])
    except ValueError:
        return {"error": f"the {name} script's last line is not JSON: {lines[-1][:200]!r}"
                         + (f" — {stderr}" if stderr else "")}
    if not isinstance(result, dict):
        return {"error": f"the {name} script must print a JSON object "
                         "{state?, toast?, error?}"}
    if "state" in result and result["state"] is not None:
        if not isinstance(result["state"], dict):
            return {"error": f"the {name} script's state must be an object"}
        try:
            json.dumps(result["state"], allow_nan=False)
        except ValueError:
            return {"error": f"the {name} script's state has NaN or Infinity in it"}
    return result


def _collect(proc: subprocess.Popen, stdin: bytes, timeout: float) -> tuple[bytes, bytes, bool, bool]:
    """Feed stdin, read stdout up to MAX_OUTPUT_BYTES (killing a runaway printer) and
    the last STDERR_TAIL*4 bytes of stderr. Returns (out, err, over_cap, timed_out)."""
    out = bytearray()
    err = bytearray()
    over = threading.Event()

    def read_out() -> None:
        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                return
            if len(out) + len(chunk) > MAX_OUTPUT_BYTES:
                over.set()
                _kill(proc)
                return
            out.extend(chunk)

    def read_err() -> None:
        while True:
            chunk = proc.stderr.read(65536)
            if not chunk:
                return
            err.extend(chunk)
            if len(err) > STDERR_TAIL * 4:
                del err[:len(err) - STDERR_TAIL * 4]

    readers = [threading.Thread(target=read_out, daemon=True),
               threading.Thread(target=read_err, daemon=True)]
    for t in readers:
        t.start()
    try:
        proc.stdin.write(stdin)
    except (BrokenPipeError, OSError):
        pass
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill(proc)
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
    for t in readers:
        t.join(timeout=5)
    return bytes(out), bytes(err), over.is_set(), timed_out


def _kill(proc: subprocess.Popen) -> None:
    try:
        if os.name == "posix":
            import signal

            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _text(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def load_state(space_id: str, timeout: float = LOAD_TIMEOUT) -> dict:
    """Run ``load``. Returns ``{"state", "error", "version"}``.

    On failure the state is the last good one this process saw (or ``{}``), so
    a broken script leaves the page showing what it showed before.
    """
    try:
        doc = get_ui(space_id)
    except Exception as exc:
        return {"state": {}, "error": str(exc), "version": None}
    if doc is None:
        return {"state": {}, "error": None, "version": None}
    return _load(space_id, doc, timeout)


def _load(space_id: str, doc: dict, timeout: float) -> dict:
    version = doc.get("version")
    script = (doc.get("scripts") or {}).get("load") or {}
    code = script.get("code") if isinstance(script, dict) else None
    if not code:
        return {"state": _cached(space_id), "error": "this UI has no load script",
                "version": version}
    payload = {"event": _event("load", None), "state": _cached(space_id),
               "integration": space_id}
    try:
        result = _run_script(space_id, "load", code, payload, timeout)
    except Exception as exc:              # never out of an HTTP handler
        result = {"error": f"the load script could not run: {exc}"}
    if result.get("error") or not isinstance(result.get("state"), dict):
        error = _text(result.get("error")) or "the load script returned no state"
        return {"state": _cached(space_id), "error": error, "version": version}
    _remember(space_id, result["state"])
    return {"state": result["state"], "error": None, "version": version}


_space_locks: dict[str, threading.Lock] = {}
_space_locks_guard = threading.Lock()


def _space_lock(space_id: str) -> threading.Lock:
    with _space_locks_guard:
        return _space_locks.setdefault(space_id, threading.Lock())


def run_action(space_id: str, action: str, event: Optional[dict] = None,
               timeout: float = ACTION_TIMEOUT) -> dict:
    """Run one action script. Returns ``{"ok", "state", "toast", "error", "version"}``."""
    try:
        doc = get_ui(space_id)
    except Exception as exc:
        return {"ok": False, "state": {}, "toast": None, "error": str(exc), "version": None}
    if doc is None:
        return {"ok": False, "state": {}, "toast": None,
                "error": f"{space_id!r} has no UI", "version": None}
    version = doc.get("version")
    scripts = doc.get("scripts") or {}
    action = str(action or "")
    if action == "load":
        out = _load(space_id, doc, min(timeout, LOAD_TIMEOUT))
        return {"ok": out["error"] is None, "state": out["state"], "toast": None,
                "error": out["error"], "version": version}
    script = scripts.get(action)
    if not action or not isinstance(script, dict) or not script.get("code"):
        return {"ok": False, "state": _cached(space_id), "toast": None,
                "error": f"this UI has no action {action!r}", "version": version}

    payload = {"event": _event(action, event), "state": _cached(space_id),
               "integration": space_id}
    # One action at a time per integration: scripts read, change and rewrite the
    # same document, so two quick taps must not interleave.
    with _space_lock(space_id):
        try:
            result = _run_script(space_id, action, script["code"], payload, timeout)
        except Exception as exc:
            result = {"error": f"the {action} script could not run: {exc}"}
    toast = _text(result.get("toast"))
    error = _text(result.get("error"))
    state = result.get("state")
    if isinstance(state, dict):
        _remember(space_id, state)
    if error:
        return {"ok": False, "state": state if isinstance(state, dict) else _cached(space_id),
                "toast": toast, "error": error, "version": version}
    if isinstance(state, dict):
        return {"ok": True, "state": state, "toast": toast, "error": None, "version": version}
    # No state: the action changed things and load says what they look like now.
    out = _load(space_id, doc, LOAD_TIMEOUT)
    return {"ok": True, "state": out["state"], "toast": toast, "error": out["error"],
            "version": version}


# ── the Integrations tab ─────────────────────────────────────────────────────
def cards(budget: float = CARDS_BUDGET) -> list[dict]:
    """Every active integration whose UI has a card, each with its loaded state.

    Loads run in parallel; one that is slow or broken carries ``error`` and the
    others still come back.
    """
    reg = _registry()
    wanted: list[tuple[dict, dict]] = []
    for row in reg.spaces():
        # A paused integration keeps its card (it can say so and offer Resume);
        # an archived one is gone from the tab.
        if row.get("status") not in ("active", "paused"):
            continue
        try:
            doc = get_ui(row["id"])
        except Exception:
            continue
        if not doc:
            continue
        card = (doc.get("presentations") or {}).get("card")
        if isinstance(card, dict):
            wanted.append((row, doc))
    if not wanted:
        return []

    pool = ThreadPoolExecutor(max_workers=min(8, len(wanted)),
                              thread_name_prefix="integration-card")
    futures = [pool.submit(_load, row["id"], doc, min(budget, LOAD_TIMEOUT))
               for row, doc in wanted]
    wait(futures, timeout=budget + 2)
    # Loads still queued past the budget never start once the reply has gone.
    pool.shutdown(wait=False, cancel_futures=True)

    out = []
    for (row, doc), future in zip(wanted, futures):
        if future.done() and future.exception() is None:
            loaded = future.result()
        else:
            loaded = {"state": _cached(row["id"]),
                      "error": "the card took too long to load"
                      if not future.done() else str(future.exception())}
        out.append({
            "id": row["id"],
            "name": row.get("name") or row["id"],
            "icon": row.get("icon") or "",
            "version": doc.get("version"),
            "card": doc["presentations"]["card"],
            "state": loaded["state"],
            "error": loaded["error"],
            "confirms": confirms(doc),
        })
    return out


__all__ = [
    "UI_KEY", "UIError", "validate_ui", "save_ui", "get_ui", "public_definition",
    "confirms", "load_state", "run_action", "cards",
]
