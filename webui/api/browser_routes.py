"""The chat's live browser card over HTTP (web + phone) — Contract A.

GET  /api/browser/sessions/<id>            the session (tools.browser_sessions.view)
POST /api/browser/sessions/<id>/move       {"to": "cloud"} → {ok, move_requested, turn_running}
POST /api/browser/sessions/<id>/takeover   {"active": bool} → {ok, takeover}
GET  /api/browser/replays/<id>.mp4         the replay (video/mp4, Range supported)

"Run on cloud browser" only flags the session: the agent's next browser call moves it
(tools/browser_tool.py). ``turn_running`` says whether a chat turn is live to make
that call; when it is false the client sends "Continue that on the cloud browser."
"""
from __future__ import annotations

import logging
import re
from typing import Any, Dict, Optional, Tuple

logger = logging.getLogger(__name__)

PATH_PREFIX = "/api/browser/"
_SESSION_RE = re.compile(r"^sessions/(b_[0-9a-f]{6,32})(?:/(move|takeover))?$")
_REPLAY_RE = re.compile(r"^replays/(b_[0-9a-f]{6,32})\.mp4$")


def is_browser_path(path: str) -> bool:
    return path.startswith(PATH_PREFIX)


def _turn_running(task_id: Optional[str]) -> bool:
    """Is a chat turn running for this browser task? Browser tasks of a webui turn
    use the chat session id as their task id (api/streaming.py)."""
    if not task_id:
        return False
    try:
        from api import config as api_config
        with api_config.ACTIVE_RUNS_LOCK:
            runs = list(api_config.ACTIVE_RUNS.values())
    except Exception:
        return False
    return any(str((run or {}).get("session_id") or "") == task_id for run in runs)


def handle_browser_request(method: str, sub: str, body: Any) -> Tuple[int, Dict[str, Any]]:
    """Route ``sub`` (the path after /api/browser/) → (status, payload)."""
    from tools import browser_sessions

    m = _SESSION_RE.match(sub or "")
    if not m:
        return 404, {"error": "not found"}
    session_id, action = m.group(1), m.group(2)
    row = browser_sessions.get(session_id)
    if row is None:
        return 404, {"error": "no such browser session"}

    if method == "GET" and action is None:
        return 200, browser_sessions.view(session_id)

    if method != "POST" or action is None:
        return 405, {"error": "method not allowed"}

    body = body if isinstance(body, dict) else {}
    current = browser_sessions.view(session_id) or {}

    if action == "move":
        if str(body.get("to") or "cloud") != "cloud":
            return 400, {"error": "to must be \"cloud\""}
        if current.get("engine") == "cloud":
            return 200, {"ok": True, "move_requested": False, "turn_running": _turn_running(row["task_id"]),
                         "note": "already on the cloud browser"}
        if not current.get("cloud_ready"):
            return 409, {"ok": False, "error": current.get("cloud_hint") or "no cloud browser is set up",
                         "move_requested": False, "turn_running": _turn_running(row["task_id"])}
        browser_sessions.request_move(session_id)
        return 200, {"ok": True, "move_requested": True, "turn_running": _turn_running(row["task_id"])}

    # takeover
    active = body.get("active")
    if not isinstance(active, bool):
        return 400, {"error": "active must be true or false"}
    if active:
        if current.get("status") != "running":
            return 409, {"ok": False, "takeover": False, "error": "this browser session has ended"}
        if not current.get("live_interactive_url"):
            return 409, {"ok": False, "takeover": False,
                         "error": "only a cloud browser with a live view can be taken over"}
    browser_sessions.set_takeover(session_id, active)
    return 200, {"ok": True, "takeover": active}


def replay_file(sub: str):
    """The replay's path for ``replays/<id>.mp4``, or None."""
    m = _REPLAY_RE.match(sub or "")
    if not m:
        return None
    from tools import browser_sessions
    path = browser_sessions.replay_path(m.group(1))
    return path if path.is_file() else None


def handle_get(handler, parsed) -> bool:
    from api.helpers import j
    sub = parsed.path[len(PATH_PREFIX):]
    if sub.startswith("replays/"):
        path = replay_file(sub)
        if path is None:
            j(handler, {"error": "no replay"}, status=404)
            return True
        from api.routes import _serve_file_bytes
        return _serve_file_bytes(handler, path, "video/mp4", "inline", "private, max-age=3600")
    try:
        status, payload = handle_browser_request("GET", sub, None)
    except Exception:
        logger.warning("browser session GET %s failed", sub, exc_info=True)
        status, payload = 500, {"error": "could not read the browser session"}
    j(handler, payload, status=status)
    return True


def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j
    sub = parsed.path[len(PATH_PREFIX):]
    try:
        status, payload = handle_browser_request("POST", sub, body)
    except Exception:
        logger.warning("browser session POST %s failed", sub, exc_info=True)
        status, payload = 500, {"error": "could not update the browser session"}
    j(handler, payload, status=status)
    return True


def route(req) -> bool:
    """Mounted at /api/browser (api/mounts.py)."""
    if req.method == "GET":
        return handle_get(req.handler, req.parsed)
    if req.method == "POST":
        return handle_post(req.handler, req.parsed, req.body)
    return False
