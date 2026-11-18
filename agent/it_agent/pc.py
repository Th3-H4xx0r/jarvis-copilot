"""Server side of the IT agent's PC tools over the device bridge (wire contracts W1/W2 in
docs/superpowers/plans/2026-11-18-it-agent.md): pc_shell runs unelevated; admin_run asks his Face ID, then
runs elevated through the Jarvis helper (or, with elevated false, unelevated — a destructive command he must
approve). Every call is watched: the PC dropping off or the card's Stop ends the wait early."""
from __future__ import annotations

import threading
from typing import Callable

from agent.it_agent.model import SIGNED_IN_SCRIPT, ShellResult

POLL_S = 5.0
APPROVAL_S = 120          # W3: his Face ID answer has 2 minutes
_NO_PC = "No PC with Jarvis (jc-client) is paired for IT tasks. Update jc-client on the PC (`jc-client update`)."


def _bridge():
    from api import device_bridge
    return device_bridge


def find_pc(text: str = "") -> tuple:
    """(device_id, name, error): the PC named in ``text``, else the first PC that offers pc_shell."""
    pcs, seen = [], set()
    for row in _bridge().catalog_device_skills():
        did = row.get("device_id")
        if row.get("name") == "pc_shell" and did and did not in seen:
            seen.add(did)
            pcs.append((did, str(row.get("device_name") or "PC")))
    if not pcs:
        return None, "", _NO_PC
    low = str(text or "").lower()
    for did, name in pcs:
        if name and name.lower() in low:
            return did, name, ""
    return pcs[0][0], pcs[0][1], ""


def online(device_id: str) -> bool:
    bridge = _bridge()
    if device_id not in set(bridge.connected_device_ids()):
        return False
    return any(s.get("name") == "pc_shell" for s in bridge.skills_for_device(device_id) or [])


def _invoke_watched(device_id: str, skill: str, args: dict, wait_s: float, should_stop: Callable[[], bool],
                    poll_s: float | None = None) -> dict:
    """invoke_skill on a daemon thread; give up early when the PC is gone at two polls in a row (offline) or
    the card's Stop is pressed (stopped). A command already running on the PC may still finish."""
    bridge = _bridge()
    box: dict = {}

    def call():
        try:
            box["out"] = bridge.invoke_skill(device_id, skill, args, timeout=wait_s)
        except Exception as exc:  # noqa: BLE001
            box["out"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    worker = threading.Thread(target=call, name=f"it-{skill}", daemon=True)
    worker.start()
    missing = 0
    poll = POLL_S if poll_s is None else poll_s
    while True:
        worker.join(timeout=poll)
        if not worker.is_alive():
            return box.get("out") or {"ok": False, "error": "no reply"}
        if should_stop():
            return {"ok": False, "error": "stopped"}
        missing = missing + 1 if device_id not in set(bridge.connected_device_ids()) else 0
        if missing >= 2:
            return {"ok": False, "error": "offline"}


def _failed(device_id: str, out: dict, routed: str) -> ShellResult:
    error = str(out.get("error") or "the PC didn't answer")
    if error in ("offline", "stopped"):
        return ShellResult(error, error=error, routed=routed)
    if device_id not in set(_bridge().connected_device_ids()):
        return ShellResult("offline", error=error, routed=routed)
    if "did not respond" in error:
        return ShellResult("timeout", error=error, routed=routed)
    return ShellResult("error", error=error, routed=routed)


def shell(device_id: str, command: str, timeout_s: int, should_stop: Callable[[], bool]) -> ShellResult:
    out = _invoke_watched(device_id, "pc_shell", {"command": command, "timeout_s": int(timeout_s)},
                          int(timeout_s) + 20, should_stop)
    res = out.get("result") if out.get("ok") else None
    if not isinstance(res, dict):
        return _failed(device_id, out, "shell")
    text = "\n".join(p for p in (str(res.get("stdout") or ""), str(res.get("stderr") or "")) if p)
    return ShellResult("timeout" if res.get("timed_out") else "ran", res.get("exit_code"), text,
                       truncated=bool(res.get("truncated")), duration_ms=int(res.get("duration_ms") or 0),
                       error=str(res.get("error") or ""))


def _admin_run(device_id: str, args: dict, timeout_s: int, should_stop, routed: str) -> ShellResult:
    out = _invoke_watched(device_id, "admin_run", args, APPROVAL_S + int(timeout_s) + 45, should_stop)
    res = out.get("result") if out.get("ok") else None
    if not isinstance(res, dict):
        return _failed(device_id, out, routed)
    status = str(res.get("status") or ("ran" if res.get("ok") else "failed"))
    status = {"failed": "error"}.get(status, status)
    if status == "ran" and res.get("timed_out"):
        status = "timeout"
    return ShellResult(status, res.get("exit_code"), str(res.get("output") or ""),
                       truncated=bool(res.get("truncated")), duration_ms=int(res.get("duration_ms") or 0),
                       error=str(res.get("error") or ""), routed=routed)


def admin(device_id: str, command: str, why: str, timeout_s: int, should_stop: Callable[[], bool]) -> ShellResult:
    """One elevated command, after his Face ID on the exact command (W2)."""
    return _admin_run(device_id, {"command": command, "why": str(why or "")[:300], "timeout_s": int(timeout_s)},
                      timeout_s, should_stop, "admin")


def approved(device_id: str, command: str, why: str, timeout_s: int,
             should_stop: Callable[[], bool]) -> ShellResult:
    """A destructive non-admin command: his Face ID on the exact command, then it runs UNELEVATED."""
    return _admin_run(device_id, {"command": command, "why": str(why or "")[:300], "timeout_s": int(timeout_s),
                                  "elevated": False}, timeout_s, should_stop, "approved")


def signed_in(device_id: str) -> bool:
    return shell(device_id, SIGNED_IN_SCRIPT, 15, lambda: False).output.strip() == "yes"
