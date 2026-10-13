"""The options a decision model picks a Mac move from, and what each one does.

A decision model can only pick a label, so every move it may make is a label:
``click N`` for each numbered element, ``fill N`` for text inputs when the step
carries text to type, plus a few fixed moves, ``done`` and ``stuck``.
"""
from __future__ import annotations

import re

TEXT_ROLES = frozenset({"AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"})

FIXED = (
    ("scroll down", "Scroll down to show more of the window"),
    ("scroll up", "Scroll back up"),
    ("press return", "Press Return (submit or confirm)"),
    ("press escape", "Press Escape (close a menu, popup or dialog)"),
    ("wait", "Wait: the screen is still loading"),
    ("done", "This step has already happened on screen"),
    ("stuck", "Nothing here moves this step forward"),
)
_KEYS = {"press return": "return", "press escape": "escape"}


def role_name(role: str) -> str:
    """``AXSearchField`` → ``search field``; other roles as given."""
    r = str(role or "")
    if r.startswith("AX"):
        r = re.sub(r"(?<!^)(?=[A-Z])", " ", r[2:]).lower()
    return r or "element"


def _thing(el: dict) -> str:
    label = str(el.get("label") or "").strip()
    return f"{role_name(el.get('role'))} '{label}'" if label else role_name(el.get("role"))


def element_line(el: dict) -> str:
    return f"{el.get('i')}. {_thing(el)}"


def build_choices(look: dict, step: dict) -> list[tuple[str, str]]:
    """``[(value, description)]`` for this screen and step."""
    text = str((step or {}).get("text") or "")
    out = []
    for el in (look or {}).get("elements") or []:
        out.append((f"click {el['i']}", f"Click the {_thing(el)}"))
        if text and el.get("role") in TEXT_ROLES:
            out.append((f"fill {el['i']}", f"Type “{text}” into the {_thing(el)}"))
    return out + list(FIXED)


_CLICK_STEP = re.compile(r"^\s*(?:click|press|tap|hit|select|choose)\s+(?:on\s+)?(?:the\s+)?['\"“‘]?(.+?)['\"”’]?"
                         r"(?:\s+(?:button|key|tab|link|item|option|icon))?\s*\.?\s*$", re.I)


# Keys drawn as a symbol carry a name in accessibility (Calculator's × is "Multiply").
_SYMBOLS = {"×": "multiply", "*": "multiply", "÷": "divide", "/": "divide", "−": "subtract", "-": "subtract",
            "+": "add", "=": "equals", "%": "percent", "⌫": "delete", "±": "change sign", "ac": "all clear"}


def match_step(step: dict, look: dict) -> int | None:
    """The element a "click the Send button" step names, when exactly one visible
    element has that label — clicked straight away, no decision call needed."""
    if (step or {}).get("text"):
        return None
    m = _CLICK_STEP.match(str((step or {}).get("do") or ""))
    if not m:
        return None
    want = m.group(1).strip().strip("'\"“”‘’").lower()
    names = {want, _SYMBOLS.get(want, want)}
    hits = [el["i"] for el in (look or {}).get("elements") or []
            if str(el.get("label") or "").strip().lower() in names]
    return hits[0] if len(hits) == 1 else None


def parse_choice(value: str, look: dict, step: dict) -> dict:
    """The ``ui_do`` action a picked value means (``stuck`` when it names nothing)."""
    v = str(value or "").strip()
    if v in ("done", "stuck", "wait"):
        return {"action": v}
    if v in _KEYS:
        return {"action": "key", "keys": _KEYS[v]}
    if v in ("scroll down", "scroll up"):
        return {"action": "scroll", "direction": v.split()[1]}
    m = re.fullmatch(r"(click|fill) (\d+)", v)
    if m and any(el.get("i") == int(m.group(2)) for el in (look or {}).get("elements") or []):
        action = {"action": m.group(1), "element": int(m.group(2))}
        if m.group(1) == "fill":
            action["text"] = str((step or {}).get("text") or "")
        return action
    return {"action": "stuck"}
