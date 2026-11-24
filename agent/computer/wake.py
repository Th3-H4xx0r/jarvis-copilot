"""Wake a sleeping Mac/PC and wait until it's ready, before acting on it — the way a person turns the PC on and
waits for it before opening anything. Live 2026-11-19: a voice turn sent the PC's wake signal, tried to launch
Battle.net the same instant, got "device not connected" and gave up (the PC was up 2 s later).

Used by computer_do (agent/computer/turns.py), every device tool on a computer (tools/device_skill_tools.py)
and computer_power's wake. Only acts in the Jarvis web server, where the power store and the bridge live.
"""
from __future__ import annotations

import logging
import time
from typing import Callable

logger = logging.getLogger(__name__)

WAIT_S = 120.0      # how long to wait for a woken computer to connect
SETTLE_S = 2.0      # after it connects: its skills register in a few frames


def _store():
    from api import mac_power
    return mac_power.store()


def _name_of(did: str) -> str:
    try:
        from api import device_bridge
        return device_bridge.device_name(did) or ""
    except Exception:  # noqa: BLE001
        return ""


def _ready(did: str) -> bool:
    """Connected, with its skills registered."""
    try:
        from api import device_bridge
        return did in set(device_bridge.connected_device_ids()) and bool(device_bridge.skills_for_device(did))
    except Exception:  # noqa: BLE001
        return False


def _rows() -> list:
    try:
        return _store().list_payload(_name_of).get("mac") or []
    except Exception:  # noqa: BLE001 — outside the web server: no power store
        return []


def sleeping_computers() -> list:
    """Paired Macs/PCs that are asleep now, as picker offers ({device_id, device_name, device_os, asleep})."""
    return [{"device_id": r["device_id"], "device_name": r.get("name") or "", "device_os": r.get("os") or "macos",
             "name": "ui_look", "asleep": True, "off": r.get("state") == "off"}
            for r in _rows() if r.get("device_id") and r.get("state") != "awake"]


def sleeping_ids() -> set:
    return {r["device_id"] for r in sleeping_computers()}


def ensure_awake(device_id: str, wait_s: float = WAIT_S, *, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep) -> tuple:
    """``(True, note)`` once the computer is up (note "" when it already was or isn't one we power), else
    ``(False, why)`` in his words."""
    row = next((r for r in _rows() if r.get("device_id") == device_id), None)
    # "starting": lit by its power button, Jarvis client not back yet — wait for it like a wake.
    if row is None or (row.get("state") == "awake" and row.get("reason") != "starting"):
        return True, ""
    noun = "PC" if (row.get("os") or "") == "windows" else "Mac"
    try:
        out = _store().wake(device_id) or {}
    except Exception as exc:  # noqa: BLE001
        return False, f"Couldn't wake the {noun}: {exc}"
    if not out.get("ok"):
        return False, str(out.get("error") or f"Couldn't wake the {noun}.")
    start = clock()
    wait_s += float(out.get("after_s") or 0)   # the server holds the press until a shutdown has finished
    while clock() - start < wait_s:
        if _ready(device_id):
            sleep(SETTLE_S)
            logger.info("woke %s in %.0f s", device_id, clock() - start)
            return True, f"The {noun} is awake."
        sleep(1.0)
    if out.get("pending"):
        return False, (f"The {noun} didn't come up yet; {out.get('via') or 'it'} picks up the wake request within "
                       f"{out.get('within_min') or 15} minutes. Try again then.")
    return False, (f"Sent the wake signal through {out.get('via') or 'another device'}, but the {noun} didn't come "
                   f"up within {int(wait_s // 60)} minutes; it picks up the request at its next 15-minute check-in.")


UNLOCK_WAIT_S = 150.0   # his Face ID on the iPhone (2 minutes) plus the typing


def _screen_on(device_id: str) -> None:
    """Turn the display on (a remote wake leaves it off — live 2026-11-20); older clients lack the skill."""
    try:
        from api import device_bridge
        device_bridge.invoke_skill(device_id, "screen_wake", {}, timeout=10.0)
    except Exception:  # noqa: BLE001
        pass


def _locked(device_id: str):
    """True/False from the computer's screen_locked skill; None when it can't say (an older jc-client)."""
    try:
        from api import device_bridge
        res = device_bridge.invoke_skill(device_id, "screen_locked", {}, timeout=10.0) or {}
    except Exception:  # noqa: BLE001
        return None
    inner = res.get("result") if isinstance(res.get("result"), dict) else {}
    if not res.get("ok") or "locked" not in inner:
        return None
    return bool(inner["locked"])


def ensure_unlocked(device_id: str, wait_s: float = UNLOCK_WAIT_S, *, clock: Callable[[], float] = time.monotonic,
                    sleep: Callable[[float], None] = time.sleep) -> tuple:
    """Before driving the screen: a locked Mac/PC is unlocked through the Face ID unlock (or his standing unlock
    permission) and waited for. ``(True, note)`` when unlocked ("" when it already was), else ``(False, why)``.
    Live 2026-11-20: woken from sleep, the PC sat at its lock screen and the task failed on it."""
    _screen_on(device_id)
    sleep(1.0)            # the lock screen appears once the display is on
    if not _locked(device_id):
        return True, ""
    try:
        out = _store().unlock(device_id) or {}
    except Exception as exc:  # noqa: BLE001
        return False, f"The screen is locked and the unlock couldn't start: {exc}"
    if not out.get("ok"):
        return False, str(out.get("error") or "The screen is locked and the unlock couldn't start.")
    start = clock()
    while clock() - start < wait_s:
        sleep(2.0)
        if _locked(device_id) is False:
            logger.info("unlocked %s in %.0f s", device_id, clock() - start)
            return True, "The screen is unlocked now."
    return False, ("The screen is still locked: approve the unlock with Face ID on your iPhone (or give Jarvis "
                   "unlock permission), then ask again.")
