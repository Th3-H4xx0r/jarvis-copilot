"""``it_task``: hand a multi-step job on the user's Windows PC — or a research question that needs several
sources — to the IT agent (agent/it_agent/). It runs as a Background job with a progress card. Listed once a
paired PC offers jc-client's ``pc_shell`` skill (the stored catalogue: stable as devices come and go)."""
from __future__ import annotations

import json

from tools.registry import registry

IT_TASK_SCHEMA = {
    "name": "it_task",
    "description": (
        "Hand a multi-step job on the user's Windows PC (install, set up, configure, update or fix software) or a "
        "research question that needs several sources to the IT agent. It researches, plans phases with checks, "
        "runs PowerShell/winget (admin and destructive steps ask his Face ID on his iPhone), handles restarts, "
        "verifies every phase and reports. It runs in the background with a progress card: say one short line "
        "and stop."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "goal": {"type": "string",
                     "description": "What should be true when it's done, in the user's words (e.g. 'Docker "
                                    "Desktop installed and running on my PC')."},
        },
        "required": ["goal"],
    },
}

_NOTE = ("The IT agent is on it in the background (progress card in this chat; admin steps ask your Face ID on "
         "your iPhone). Tell the user that in one short line and stop.")


def _start(task_id, goal: str) -> dict:
    try:
        from api.it_jobs import start_it_job
    except Exception as exc:  # outside the Jarvis web server there is no job runner
        return {"ok": False, "error": f"IT tasks run in the Jarvis server only ({exc})."}
    return start_it_job(task_id, goal)


def handle_it_task(args: dict, task_id=None, **_kw) -> str:
    goal = str((args or {}).get("goal") or "").strip()
    if not goal:
        return json.dumps({"ok": False, "error": "goal is required"})
    out = _start(task_id, goal)
    if not out.get("ok"):
        return json.dumps({"ok": False, "error": out.get("error") or "The IT agent couldn't start."})
    from agent import escalation
    escalation.mark_handed_off(task_id)
    return json.dumps({"ok": True, "job_id": out.get("job_id"), "note": _NOTE})


def check_it_task() -> bool:
    """A paired PC offers ``pc_shell``."""
    try:
        from api import device_bridge
        return any(isinstance(e, dict) and e.get("name") == "pc_shell" for e in device_bridge.catalog_device_skills())
    except Exception:
        return False


registry.register(
    name="it_task",
    toolset="it_task",
    schema=IT_TASK_SCHEMA,
    handler=lambda args, **kw: handle_it_task(args, **kw),
    check_fn=lambda: check_it_task(),
    emoji="🛠️",
)
