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
        "and a screenshot; if it stops stuck, continue from there yourself. A sleeping or locked computer is woken "
        "and unlocked first (no separate wake or unlock call). Prefer it over chrome_* and "
        "mouse/keyboard tools for anything on the Mac. Reads use the whole page's text, so don't add steps "
        "that only scroll to read."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "goal": {"type": "string", "description": "What should be true on the computer when done."},
            "computer": {"type": "string",
                         "description": "Which of his computers: 'PC' (Windows) or 'Mac'. He rarely says — infer it "
                                        "from the conversation (a PC chat stays on the PC) and from the app (Windows "
                                        "games and launchers like Battle.net or Steam are on the PC). A sleeping "
                                        "computer is woken and waited for first."},
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
                        "app": {"type": "string", "description": "App to open first, if any (for url: the browser)."},
                        "url": {"type": "string", "description": "A web page to open directly (never type URLs)."},
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
    from agent.it_agent import handover
    goal = str((args or {}).get("goal") or "").strip()
    if not goal:
        return json.dumps({"ok": False, "error": "goal is required"})
    handed = handover.maybe_hand_over(goal, task_id)   # installs/setup on the PC → the IT agent
    if handed:
        return handed
    result, err = turns.run_task(goal, (args or {}).get("steps"), task_id, app=(args or {}).get("app"),
                                 prefer=str((args or {}).get("computer") or "").strip())
    if err:
        return json.dumps({"ok": False, "error": err})
    if result.status == "stuck":
        hint = handover.limit_hint(result, handover.device_os(task_id))
        if hint:
            result.reason = f"{result.reason or ''}{hint}"
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
