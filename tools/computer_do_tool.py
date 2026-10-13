"""``computer_do``: have the fast loop drive the user's Mac for one sub-goal.

A decision model picks each click from a numbered screenshot (agent/computer/);
the main model only says what to do. Listed once a paired device offers
jc-client's ``ui_look`` skill. Only runs when the user asked for their Mac
(agent/mac_browser_gate.py).
"""
from __future__ import annotations

import json

from tools.registry import registry

COMPUTER_DO_SCHEMA = {
    "name": "computer_do",
    "description": (
        "Do something on the user's Mac fast: a decision model clicks and types through the UI one step at a "
        "time from screenshots. Only when the user asked for their Mac/computer. Give `steps` with the exact "
        "text to type (it skips a planning call). Returns what happened, the final screen's numbered elements "
        "and a screenshot; if it stops stuck, continue from there yourself. Prefer it over chrome_* and "
        "mouse/keyboard tools for anything on the Mac."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "goal": {"type": "string", "description": "What should be true on the Mac when done."},
            "app": {"type": "string", "description": "The app it happens in, e.g. 'Calculator' (opened if needed; "
                                                    "works even when another app is in front)."},
            "steps": {
                "type": "array",
                "description": "Short UI steps in order.",
                "items": {
                    "type": "object",
                    "properties": {
                        "do": {"type": "string", "description": "One step, e.g. 'search for the song'."},
                        "text": {"type": "string", "description": "Exact text to type in this step, if any."},
                        "app": {"type": "string", "description": "App to open first, if any."},
                    },
                    "required": ["do"],
                },
            },
        },
        "required": ["goal"],
    },
}


def handle_computer_do(args: dict, task_id=None, **_kw):
    from agent.computer import turns
    goal = str((args or {}).get("goal") or "").strip()
    if not goal:
        return json.dumps({"ok": False, "error": "goal is required"})
    result, err = turns.run_task(goal, (args or {}).get("steps"), task_id, app=(args or {}).get("app"))
    if err:
        return json.dumps({"ok": False, "error": err})
    return turns.tool_result(result)


def check_computer_do() -> bool:
    """A paired device offers ``ui_look`` (the stored catalogue: stable as devices come and go)."""
    try:
        from api import device_bridge
        return any(isinstance(e, dict) and e.get("name") == "ui_look" for e in device_bridge.catalog_device_skills())
    except Exception:
        return False


registry.register(
    name="computer_do",
    toolset="computer_do",
    schema=COMPUTER_DO_SCHEMA,
    handler=lambda args, **kw: handle_computer_do(args, **kw),
    check_fn=check_computer_do,
    emoji="🖱️",
)
