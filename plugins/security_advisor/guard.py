"""Inline taint guard: a turn that read a prompt injection can't run risky tools.

Runs as plugin hooks in every process that runs an agent (webui, gateway, cron).
Pure Python and in-memory, like ``agent/mac_browser_gate.py``: the only I/O is a
non-blocking ``emit()``.

A turn (``task_id``) is tainted when the injection scanner flags content that
entered it: the inbound message of a gateway/cron/email turn, or the result of a
content-reading tool. Reading untrusted content alone does not taint. In a
tainted turn, risky tools are refused. His own next message (from a paired
surface) starts clean.
"""
from __future__ import annotations

import threading
import time
from collections import OrderedDict

from security.injection import BLOCK_THRESHOLD, REVIEW_THRESHOLD, scan

clock = time.time
MAX_TAINTED = 2000
# Scan at most this much of one message/result (its head and tail): the scan runs inline
# in the agent loop, and injected instructions sit at the start or end of a page.
SCAN_MAX_CHARS = 32_000
TAINT_TTL_S = 6 * 3600

# Tools whose results are untrusted outside content: web pages, the server's
# browser, his Mac browser, MCP servers, X search, image/video descriptions.
CONTENT_PREFIXES = ("web_", "browser_", "chrome_", "device_chrome_", "mcp_")
CONTENT_NAMES = frozenset({"x_search", "vision_analyze", "video_analyze"})
# Email is read with the himalaya CLI through the terminal tool.
_EMAIL_READ_MARKERS = ("himalaya",)

# Tools that act: shell/code, file writes, sends, the car, the door, his devices,
# skills, schedules, subagents, Home Assistant, coding sessions, integration scripts.
RISKY_NAMES = frozenset({
    "terminal", "process", "execute_code", "write_file", "patch",
    "send_message", "send_email", "skill_manage", "cronjob", "delegate_task",
    "toyota_command", "toyota_climate",
    "door_arm", "door_disarm", "door_silence", "door_set", "door_settings",
    "ha_call_service", "coding_session_launch", "coding_session_message",
    "integration_create", "integration_ui_set",
})
RISKY_PREFIXES = ("device_", "computer_", "chrome_")

# Surfaces where the turn's text is Pranav's own words (a paired device, his shell).
TRUSTED_PLATFORMS = frozenset({
    "", "cli", "tui", "webui", "web", "voice", "ios", "iphone", "mac", "macos", "acp",
    "api_server", "curator",
})

_TAINT: "OrderedDict[str, tuple[str, float]]" = OrderedDict()
_LOCK = threading.Lock()


def is_content_tool(name: str) -> bool:
    name = name or ""
    return name in CONTENT_NAMES or name.startswith(CONTENT_PREFIXES)


def is_risky(name: str) -> bool:
    name = name or ""
    return name in RISKY_NAMES or name.startswith(RISKY_PREFIXES)


def _emit(kind: str, actor: dict | None = None, **detail) -> None:
    from security import events
    events.emit("agent", kind, actor or {}, **detail)


def _taint(task_id: str, source: str) -> None:
    with _LOCK:
        _TAINT[task_id] = (source, clock())
        _TAINT.move_to_end(task_id)
        while len(_TAINT) > MAX_TAINTED:
            _TAINT.popitem(last=False)


def _tainted_by(task_id: str) -> str | None:
    with _LOCK:
        entry = _TAINT.get(task_id)
        if entry is None:
            return None
        source, ts = entry
        if clock() - ts > TAINT_TTL_S:
            _TAINT.pop(task_id, None)
            return None
        return source


def _flagged(text, threshold: float):
    if not isinstance(text, str):
        text = "" if text is None else str(text)
    if not text:
        return None
    if len(text) > SCAN_MAX_CHARS:
        half = SCAN_MAX_CHARS // 2
        text = text[:half] + "\n" + text[-half:]
    score, labels = scan(text)
    return (score, labels) if score >= threshold else None


# ── hooks ────────────────────────────────────────────────────────────────

def on_pre_llm_call(task_id="", user_message="", platform="", sender_id="", **kw) -> None:
    try:
        if not task_id:
            return None
        platform = str(platform or "").lower()
        if platform in TRUSTED_PLATFORMS:
            with _LOCK:
                _TAINT.pop(task_id, None)  # his own new message: the turn starts clean
            return None
        hit = _flagged(user_message, BLOCK_THRESHOLD)
        if hit:
            source = f"{platform} message"
            _taint(task_id, source)
            _emit("inject.detected", {"platform": platform, "sender_id": str(sender_id or "")},
                  origin=source, score=round(hit[0], 2), labels=hit[1], task_id=task_id)
    except Exception:
        pass
    return None


def on_post_tool_call(tool_name="", args=None, result=None, task_id="", **kw) -> None:
    try:
        if not task_id:
            return None
        content = is_content_tool(tool_name)
        if not content and tool_name == "terminal" and isinstance(args, dict):
            command = str(args.get("command") or "")
            content = any(m in command for m in _EMAIL_READ_MARKERS)
        if not content:
            return None
        hit = _flagged(result, REVIEW_THRESHOLD)
        if hit:
            _taint(task_id, tool_name)
            _emit("inject.detected", {}, origin=tool_name, score=round(hit[0], 2),
                  labels=hit[1], task_id=task_id)
    except Exception:
        pass
    return None


def on_pre_tool_call(tool_name="", args=None, task_id="", **kw):
    try:
        if not is_risky(tool_name):
            return None
        source = _tainted_by(task_id) if task_id else None
        _emit("tool.risky", {}, tool=tool_name, task_id=task_id, tainted=bool(source))
        if not source:
            return None
        _emit("agent.blocked", {}, tool=tool_name, origin=source, task_id=task_id)
        return {
            "action": "block",
            "message": (f"Blocked by Security Advisor: this turn read content that looks like a "
                        f"prompt injection ({source}), so {tool_name} can't run in it. "
                        f"Ask Pranav to confirm in a new message."),
        }
    except Exception:
        return None


def on_pre_approval_request(command="", pattern_key="", session_key="", surface="", **kw) -> None:
    try:
        _emit("approval.requested", {"session_key": str(session_key or "")},
              pattern=str(pattern_key or ""), surface=str(surface or ""),
              command=str(command or "")[:200])
    except Exception:
        pass
    return None


def on_post_approval_response(command="", pattern_key="", session_key="", surface="", choice=None,
                              **kw) -> None:
    try:
        _emit("approval.result", {"session_key": str(session_key or "")},
              pattern=str(pattern_key or ""), surface=str(surface or ""),
              choice=str(choice or ""), command=str(command or "")[:200])
    except Exception:
        pass
    return None


def on_pre_gateway_dispatch(event=None, **kw) -> None:
    """Log who sent a gateway message (never its text). Never drops the message."""
    try:
        src = getattr(event, "source", None)
        platform = getattr(src, "platform", "") if src is not None else ""
        platform = str(getattr(platform, "value", platform) or "")
        _emit("gateway.message",
              {"sender_id": str(getattr(src, "user_id", "") or ""),
               "chat_id": str(getattr(src, "chat_id", "") or "")},
              platform=platform)
    except Exception:
        pass
    return None
