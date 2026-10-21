"""jarvis-island: report Jarvis's own runs to the agent tracker.

Each turn becomes the same hook events a coding agent sends (prompt, tool
calls, approvals, the reply) as agent ``jarvis`` on the tracker's socket
(``$HERMES_HOME/agent-hook.sock``), so the Mac island and the iPhone Agents
tab show Jarvis working next to Claude Code. After coucou's Hermes plugin
(github.com/Louis-CFM/coucou, MIT).

Display only: events go, in order, through one daemon sender thread with a
short timeout per send (a full queue drops them), nothing is ever raised into the agent, and cron runs are left out
(they would fill the island every fifteen minutes).
"""
from __future__ import annotations

import json
import os
import queue
import socket
import threading

_SKIP_PLATFORMS = {"cron"}
# Platforms an integration's background runs use -> the name its group shows.
_INTEGRATIONS = {"imessage_memory": "iMessage memory"}
_TIMEOUT = 0.3
_local = threading.local()
_platforms: dict = {}  # session_id -> platform, so tool events know whether to skip


def _socket_path() -> str:
    try:
        from jarviscopilot_constants import get_hermes_home
        return str(get_hermes_home() / "agent-hook.sock")
    except Exception:  # noqa: BLE001
        return os.path.join(os.path.expanduser("~"), ".jarviscopilot", "agent-hook.sock")


def _send(frame: dict) -> None:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(_TIMEOUT)
    try:
        s.connect(_socket_path())
        s.sendall((json.dumps(frame, default=str) + "\n").encode())
    except OSError:
        pass
    finally:
        s.close()


def _fire(event: str, session_id: str, **fields) -> None:
    if not session_id:
        return
    payload = {"hook_event_name": event, "session_id": session_id, "cwd": ""}
    payload.update({k: v for k, v in fields.items() if v is not None})
    frame = {"jc": 1, "kind": "event", "agent": "jarvis", "payload": payload}
    try:
        _ensure_sender()
        _queue.put_nowait(frame)
    except Exception:  # noqa: BLE001
        pass


_queue: "queue.Queue[dict]" = queue.Queue(maxsize=500)
_sender_lock = threading.Lock()
_sender = None


def _ensure_sender() -> None:
    global _sender
    if _sender is not None and _sender.is_alive():
        return
    with _sender_lock:
        if _sender is None or not _sender.is_alive():
            _sender = threading.Thread(target=_drain, name="jarvis-island", daemon=True)
            _sender.start()


def _drain() -> None:
    while True:
        frame = _queue.get()
        try:
            _send(frame)
        except Exception:  # noqa: BLE001
            pass


def _shrink(node, n: int = 1500, k: int = 40, depth: int = 0):
    """Tool arguments as the island shows them: strings cut to ``n`` chars,
    lists and dicts to ``k`` items, nothing nested past four levels."""
    if isinstance(node, str):
        return node if len(node) <= n else node[:n] + "…"
    if depth >= 4:
        return "…"
    if isinstance(node, list):
        out = [_shrink(v, n, k, depth + 1) for v in node[:k]]
        return out + ([f"…{len(node) - k} more"] if len(node) > k else [])
    if isinstance(node, dict):
        return {str(key)[:80]: _shrink(v, n, k, depth + 1) for key, v in list(node.items())[:k]}
    return node


def _skipped(session_id: str, platform: str = "") -> bool:
    platform = platform or _platforms.get(session_id, "")
    return platform in _SKIP_PLATFORMS


def _pre_llm_call(session_id: str = "", user_message="", platform: str = "", **_kw) -> None:
    try:
        _platforms[session_id] = platform or ""
        if len(_platforms) > 512:
            _platforms.pop(next(iter(_platforms)))
        if _skipped(session_id, platform):
            return
        prompt = user_message if isinstance(user_message, str) else ""
        integration = _INTEGRATIONS.get(platform or "")
        if integration:
            # A background run for an integration: grouped (collapsed) under it
            # in the Agents tab, not one session each among his chats.
            _fire("UserPromptSubmit", session_id, prompt=prompt[:500],
                  jc_project=integration, jc_integration=integration)
            return
        _fire("UserPromptSubmit", session_id, prompt=prompt[:500],
              jc_project=f"Jarvis · {platform or 'chat'}")
    except Exception:  # noqa: BLE001
        pass


def _pre_tool_call(tool_name: str = "", args=None, session_id: str = "",
                   tool_call_id: str = "", **_kw) -> None:
    try:
        _local.session_id = session_id
        if _skipped(session_id):
            return
        _fire("PreToolUse", session_id, tool_name=tool_name,
              tool_input=_shrink(args) if isinstance(args, dict) else {}, tool_use_id=tool_call_id or None)
    except Exception:  # noqa: BLE001
        pass


def _post_tool_call(tool_name: str = "", args=None, result=None, session_id: str = "",
                    tool_call_id: str = "", **_kw) -> None:
    try:
        if _skipped(session_id):
            return
        out = result if isinstance(result, str) else ""
        _fire("PostToolUse", session_id, tool_name=tool_name,
              tool_input=_shrink(args) if isinstance(args, dict) else {}, tool_use_id=tool_call_id or None,
              tool_response=out[:2000])
    except Exception:  # noqa: BLE001
        pass


def _post_llm_call(session_id: str = "", assistant_response="", platform: str = "", **_kw) -> None:
    try:
        if _skipped(session_id, platform):
            return
        reply = assistant_response if isinstance(assistant_response, str) else ""
        _fire("Stop", session_id, last_assistant_message=reply[:2000])
    except Exception:  # noqa: BLE001
        pass


def _pre_approval_request(command: str = "", description: str = "", **_kw) -> None:
    """Approvals run inside the tool call, on its thread: that names the session."""
    try:
        session_id = getattr(_local, "session_id", "") or ""
        if _skipped(session_id):
            return
        what = f"{description}: {command}" if description else command
        _fire("Notification", session_id, notification_type="permission_prompt",
              message=f"Jarvis needs your approval — {what}"[:300])
    except Exception:  # noqa: BLE001
        pass


def register(ctx) -> None:
    ctx.register_hook("pre_llm_call", _pre_llm_call)
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    ctx.register_hook("post_tool_call", _post_tool_call)
    ctx.register_hook("post_llm_call", _post_llm_call)
    ctx.register_hook("pre_approval_request", _pre_approval_request)
