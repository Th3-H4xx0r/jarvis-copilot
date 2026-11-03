"""A Mac screen share for each computer task (Contract B: ``reason: "task"``).

The Mac app sees the requested share, captures the display (the chat's
``mac_screen`` card watches it live over WebRTC) and records it; ending the
share when the task ends makes the Mac upload the replay. In the web UI process
the share registry is in memory; elsewhere (the messaging gateway, the
scheduler) the same calls go through the web UI's REST API, host-signed.
Never fatal: a task without a share still runs.
"""
from __future__ import annotations

import logging
import sys
from typing import Optional

logger = logging.getLogger(__name__)


def _in_process():
    if "webui.server" not in sys.modules:
        return None
    try:
        from api import screen_share
        return screen_share
    except Exception:
        return None


def start(goal: str, task_id=None) -> Optional[str]:
    """The new share's id, or None when it could not be requested."""
    try:
        mod = _in_process()
        if mod is not None:
            share = mod.start_task_share(str(goal or "")[:300], str(task_id or ""))
        else:
            from tools.chrome_device_tool import _api_request
            share = _api_request("POST", "/api/screen/shares",
                                 body={"reason": "task", "task": str(goal or "")[:300],
                                       "session_id": str(task_id or "")}, timeout=5.0)
        sid = (share or {}).get("id") if isinstance(share, dict) else None
        return str(sid) if sid else None
    except Exception as exc:  # noqa: BLE001 — the task matters more than its preview
        logger.info("computer task: no screen share (%s)", exc)
        return None


def end(share_id: Optional[str]) -> None:
    if not share_id:
        return
    try:
        mod = _in_process()
        if mod is not None:
            mod.end_share(share_id)
        else:
            from tools.chrome_device_tool import _api_request
            _api_request("POST", f"/api/screen/shares/{share_id}/stop", body={}, timeout=5.0)
    except Exception as exc:  # noqa: BLE001
        logger.info("computer task: could not end screen share %s (%s)", share_id, exc)


def card(share_id: Optional[str]) -> Optional[dict]:
    return {"kind": "mac_screen", "share": share_id} if share_id else None
