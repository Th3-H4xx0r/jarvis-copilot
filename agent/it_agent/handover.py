"""computer_do → it_task: installs and multi-step setup on the PC go to the IT agent (terminal-first, phases
with checks) instead of the fast hands; the fast hands suggest it_task when they hit their limits on the PC."""
from __future__ import annotations

import json
import re

_PAST_LIMITS = re.compile(
    r"\b(?:install|uninstall|reinstall|upgrade|update (?:windows|drivers?|bios|firmware)|"
    r"enable (?:wsl2?|hyper-?v|virtuali[sz]ation|virtual machine platform)|troubleshoot|diagnose|repair|"
    r"drivers?)\b", re.I)
_HINT = "\nPast the fast hands' limits: for installs or multi-step setup on the PC, use it_task."
_NOTE = ("Installs and setup on the PC run as IT tasks: the IT agent is doing it in the background with a progress "
         "card. Tell the user in one short line and stop.")


def past_limits(goal) -> bool:
    return bool(_PAST_LIMITS.search(str(goal or "")))


def _available() -> bool:
    from tools.it_task_tool import check_it_task
    return check_it_task()


def _start(task_id, goal: str) -> dict:
    from tools.it_task_tool import _start as start
    return start(task_id, goal)


def device_os(task_id) -> str:
    from agent.computer import mac
    device, _, err = mac.find_mac(task_id)
    return mac.os_of(device) if device and not err else ""


def maybe_hand_over(goal, task_id):
    """The hand-over's tool result, or None to let the fast hands do it (a Mac, a short task, no IT agent,
    or it couldn't start)."""
    if not past_limits(goal) or not _available() or device_os(task_id) != "windows":
        return None
    out = _start(task_id, str(goal))
    if not out.get("ok"):
        return None
    from agent import escalation
    escalation.mark_handed_off(task_id)
    return json.dumps({"ok": True, "handed_over": "it_task", "job_id": out.get("job_id"), "note": _NOTE})


def limit_hint(result, device_os_name: str) -> str:
    reason = str(getattr(result, "reason", "") or "")
    if (getattr(result, "status", "") == "stuck" and reason.startswith(("Reached the", "Ran out of time"))
            and device_os_name == "windows" and _available()):
        return _HINT
    return ""
