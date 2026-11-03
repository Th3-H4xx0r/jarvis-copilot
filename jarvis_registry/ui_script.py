"""One-liners for an integration UI's scripts.

A UI script (``load`` or an action) runs as its own Python process. It gets a JSON
object on stdin — ``{"event": {action, control, value, inputs, row}, "state": {...},
"integration": "<space id>"}`` — and answers with one JSON line on stdout:
``{"state"?: {...}, "toast"?: "text", "error"?: "text"}``. These helpers do both
ends::

    from jarvis_registry import ui_script as u

    s = u.space()                                  # this integration's registry space
    name = (u.inputs().get("new_item") or "").strip()
    if not name:
        u.fail("Type something to add")
    s.append("items", {"name": name, "done": False})
    u.reply(toast=f"Added {name}")                 # no state: load runs again

Anything printed before the final line is ignored, so ``print`` debugging is fine.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any, NoReturn, Optional

_payload: Optional[dict] = None
_space = None


def payload() -> dict:
    """Everything the server sent, read from stdin once."""
    global _payload
    if _payload is None:
        try:
            raw = sys.stdin.read()
            data = json.loads(raw) if raw.strip() else {}
        except (OSError, ValueError):
            data = {}
        _payload = data if isinstance(data, dict) else {}
    return _payload


def event() -> dict:
    """``{action, control, value, inputs, row}`` for the interaction being run."""
    ev = payload().get("event")
    return ev if isinstance(ev, dict) else {}


def state() -> dict:
    """The state the UI showed last (``{}`` when the server has none yet)."""
    st = payload().get("state")
    return st if isinstance(st, dict) else {}


def inputs() -> dict:
    """The page's input controls by id: ``{"new_item": "Milk", "qty": 2}``."""
    ins = event().get("inputs")
    return ins if isinstance(ins, dict) else {}


def row() -> Optional[dict]:
    """The list row the tapped control belongs to, or None outside a list."""
    r = event().get("row")
    return r if isinstance(r, dict) else None


def value() -> Any:
    """The control's own new value (a toggle's bool, a picker's choice, …)."""
    return event().get("value")


def integration() -> str:
    """This integration's space id."""
    return str(payload().get("integration") or os.environ.get("JARVIS_UI_SPACE") or "")


def space():
    """This integration's registry space (get/put documents, append/records)."""
    global _space
    if _space is None:
        from jarvis_registry.store import Registry, shared

        path = os.environ.get("JARVIS_REGISTRY_PATH")
        reg = Registry(path) if path else shared()
        _space = reg.open(integration())
    return _space


def other_space(space_id: str):
    """Another integration's space, to read (or write) its data."""
    from jarvis_registry.store import Registry, shared

    path = os.environ.get("JARVIS_REGISTRY_PATH")
    reg = Registry(path) if path else shared()
    return reg.open(space_id)


def reply(state: Optional[dict] = None, toast: Optional[str] = None) -> NoReturn:
    """Answer and exit. Without ``state`` the server runs ``load`` again."""
    out: dict = {}
    if state is not None:
        out["state"] = state
    if toast:
        out["toast"] = str(toast)
    _emit(out)


def fail(message: str) -> NoReturn:
    """Stop and show ``message`` to the person; nothing they see changes."""
    _emit({"error": str(message)})


def _emit(body: dict) -> NoReturn:
    sys.stdout.write("\n" + json.dumps(body, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()
    sys.exit(0)


__all__ = ["payload", "event", "state", "inputs", "row", "value", "integration",
           "space", "other_space", "reply", "fail"]
