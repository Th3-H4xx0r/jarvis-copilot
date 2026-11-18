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


def _other_tab(el: dict, step: dict) -> bool:
    """A browser tab is only a move when the step is about tabs (live: the decider kept
    clicking the tab titled like the result it wanted)."""
    kind = str(el.get("kind") or "").lower()
    return kind == "tab" and "tab" not in str((step or {}).get("do") or "").lower()


# Window controls close / zoom / minimise / full-screen whatever is in front (live: a fallback model
# clicked all of them on a notifications step): a move only when the step asks for it.
_WINDOW_CONTROL = re.compile(r"^\s*(?:close|zoom|minimi[sz]e|full\s*screen)\s+button\b", re.I)


def _permission(el: dict, step: dict) -> bool:
    """Not a move for this step: an Allow/Accept prompt, or a window control, it didn't ask for."""
    label = str(el.get("label") or "")
    words = str((step or {}).get("do") or "").lower()
    if _WINDOW_CONTROL.match(label):
        return not any(w in words for w in ("close", "zoom", "minimi", "full screen", "fullscreen", "maximi"))
    if not _PERMISSION.match(label):
        return False
    return not any(w in words for w in ("allow", "accept", "agree"))


def element_line(el: dict) -> str:
    return f"{el.get('i')}. {_thing(el)}"


def build_choices(look: dict, step: dict) -> list[tuple[str, str]]:
    """``[(value, description)]`` for this screen and step."""
    text = str((step or {}).get("text") or "")
    out = []
    for el in (look or {}).get("elements") or []:
        if _permission(el, step) or _other_tab(el, step):
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


# A step that is one move ("click the first result", "press Return"): done once that move works.
ONE_MOVE = re.compile(r"^\s*(?:click|press|tap|hit|select|choose|pick|open)\b(?!.*\b(?:and|then|until)\b)", re.I)

# Steps about a surface rather than a window (jc-client reads them with agent-desktop). Only when the
# step names the surface: System Settings has panes called Wi-Fi, Battery, Notifications, Desktop & Dock.
_MENU_BAR = re.compile(r"\bmenu[- ]?bar\b", re.I)
_MENU_BAR_ITEM = re.compile(r"\b(?:icon|extra|status|wi-?fi|bluetooth|battery|volume|sound|clock|control\s+cent(?:er|re))",
                            re.I)
_APP_MENU = re.compile(r"›|\b(?:file|edit|view|window|help|format|go|history|bookmarks|insert|tools)\s+menu\b", re.I)
_DOCK = re.compile(r"\b(?:the|in|from|on)\s+(?:the\s+)?Dock\b")
_NOTIFICATION = re.compile(r"\bnotification\s+cent(?:er|re)\b|\b(?:latest|recent|last|new|unread|my)\s+notifications?\b",
                           re.I)
_NO_SURFACES = frozenset({"system settings", "system preferences"})


def surface_for(step: dict, anchor: str | None = None) -> str | None:
    """The surface a step is about — "menubar", "menu-bar-extras", "dock", "notifications" — or None."""
    if str(anchor or "").strip().lower() in _NO_SURFACES:
        return None
    do = str((step or {}).get("do") or "")
    if _MENU_BAR.search(do):
        return "menu-bar-extras" if _MENU_BAR_ITEM.search(do) else "menubar"
    if _NOTIFICATION.search(do):
        return "notifications"
    if _DOCK.search(do):
        return "dock"
    if _APP_MENU.search(do):
        return "menubar"
    return None


def batch_run(steps: list, at: int, look: dict) -> list:
    """From step ``at``, the run of one-move named clicks all findable in this look (2, 3, ×, 4, =):
    ``[(step_index, element)]`` pressed in one trip — empty for fewer than two."""
    run = []
    for i in range(at, len(steps)):
        step = steps[i] or {}
        if any(step.get(k) for k in ("app", "url", "text", "read")) or not ONE_MOVE.match(str(step.get("do") or "")):
            break
        element = match_step(step, look)
        if element is None:
            break
        run.append((i, element))
    return run if len(run) >= 2 else []


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
