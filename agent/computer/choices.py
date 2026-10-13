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
    kind = str(el.get("kind") or "").strip().lower() or role_name(el.get("role"))  # macOS's "tab", "link"…
    return f"{kind} '{label}'" if label else kind


# Granting a site permission or accepting terms is never a move the task didn't ask for.
_PERMISSION = re.compile(r"^\s*(?:allow|always allow|allow once|accept(?:\s+all)?(?:\s+cookies)?|agree|i agree|"
                         r"accept\s*&\s*continue)\s*$", re.I)


def _permission(el: dict, step: dict) -> bool:
    label = str(el.get("label") or "")
    if not _PERMISSION.match(label):
        return False
    words = str((step or {}).get("do") or "").lower()
    return not any(w in words for w in ("allow", "accept", "agree"))


def element_line(el: dict) -> str:
    return f"{el.get('i')}. {_thing(el)}"


def build_choices(look: dict, step: dict) -> list[tuple[str, str]]:
    """``[(value, description)]`` for this screen and step."""
    text = str((step or {}).get("text") or "")
    out = []
    for el in (look or {}).get("elements") or []:
        if _permission(el, step):
            continue
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
        # (Not for the navigation steps a read adds: they quote the read's own words.)
        return None if (step or {}).get("_max") else _named_in_passing(str((step or {}).get("do") or ""), look)
    want = m.group(1).strip().strip("'\"“”‘’").lower()
    names = {want, _SYMBOLS.get(want, want)}
    hits = [el["i"] for el in (look or {}).get("elements") or []
            if str(el.get("label") or "").strip().lower() in names]
    return hits[0] if len(hits) == 1 else None


def _named_in_passing(do: str, look: dict) -> int | None:
    """"create a new note" → the one "New Note" button; "open the Downloads folder" →
    the one "Downloads" row. Only labels of 5+ letters, as whole words, one hit."""
    low = do.lower()
    hits = [el["i"] for el in (look or {}).get("elements") or []
            if len(str(el.get("label") or "").strip()) >= 5
            and re.search(rf"(?<!\w){re.escape(str(el['label']).strip().lower())}(?!\w)", low)]
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
    el = next((e for e in (look or {}).get("elements") or [] if m and e.get("i") == int(m.group(2))), None)
    if m and el is not None and not _permission(el, step):
        action = {"action": m.group(1), "element": int(m.group(2))}
        if m.group(1) == "fill":
            action["text"] = str((step or {}).get("text") or "")
        return action
    return {"action": "stuck"}
