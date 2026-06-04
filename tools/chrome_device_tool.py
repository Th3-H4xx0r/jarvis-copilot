"""Direct ``chrome_*`` AGENT tools for driving the user's real, visible Chrome on
a paired Mac (A2 "speed" path).

The Mac client advertises ``chrome_*`` **device skills** (desktop_client/.../
skills/browser.py) that drive a real Playwright-extension Chrome. Previously the
agent reached them the slow way — read the devices SKILL.md, shell out to
``devices.py invoke`` through the terminal, parse the output. These tools wrap the
same device skills as first-class agent tools: the handler calls ``invoke_skill``
over the device bridge directly (in-process, synchronous) and truncates the
returned snapshot the same way the server's own browser tool does.

Under lazy tool-loading these are deferred (manifest) and surface only when a
chrome-capable device is online (``check_fn``); the agent tool_searches them once,
then drives Chrome with direct tool calls — no terminal, no SKILL.md round-trip.
"""
from __future__ import annotations

import json
from typing import Optional, Tuple

from tools.registry import registry

_CALL_TIMEOUT = 90.0  # generous for slow page loads / cold extension attach
_SNAPSHOT_SKILL = "chrome_navigate"  # the marker skill a chrome-capable device advertises


# ── device resolution ────────────────────────────────────────────────────────

def _resolve_chrome_device() -> Optional[str]:
    """device_id of a connected device advertising the chrome skills, else None."""
    try:
        from webui.api.device_bridge import connected_device_ids, skills_for_device
    except Exception:
        return None
    for did in connected_device_ids():
        try:
            if any(s.get("name") == _SNAPSHOT_SKILL for s in skills_for_device(did)):
                return did
        except Exception:
            continue
    return None


def _chrome_available() -> bool:
    """check_fn: only advertise these tools when a chrome-capable device is online."""
    try:
        return _resolve_chrome_device() is not None
    except Exception:
        return False


# ── result handling ──────────────────────────────────────────────────────────

def _extract_snapshot(invoke_result: dict) -> Tuple[str, Optional[str]]:
    """Unwrap ``invoke_skill``'s ``{ok,result}`` AND the device skill's own inner
    ``{ok,result}`` (browser_mcp returns that). Returns ``(text, error)``."""
    if not isinstance(invoke_result, dict) or not invoke_result.get("ok"):
        err = (invoke_result or {}).get("error") if isinstance(invoke_result, dict) else None
        return "", err or "device offline or skill failed"
    inner = invoke_result.get("result")
    if isinstance(inner, dict):
        if inner.get("ok") is False:
            return "", str(inner.get("error") or inner.get("result") or "chrome skill error")
        text = inner.get("result", "")
    else:
        text = inner
    if not isinstance(text, str):
        text = json.dumps(text)
    return text, None


def _truncate(text: str) -> str:
    """Server-side structure-aware cap (mirrors the headless browser tool). The
    device side already caps too; this is the belt-and-suspenders server bound."""
    try:
        from tools.browser_tool import _truncate_snapshot
        return _truncate_snapshot(text)
    except Exception:
        # Local fallback if the browser tool can't be imported.
        if len(text) <= 8000:
            return text
        cut = text[:8000].rsplit("\n", 1)[0]
        return cut + "\n[... snapshot truncated]"


def _chrome_call(skill_name: str, args: dict) -> str:
    dev = _resolve_chrome_device()
    if not dev:
        return json.dumps({"error": "No Mac with Chrome is paired and online. "
                           "Ensure the JarvisCopilot Mac client is running and the "
                           "Playwright Chrome extension is connected."})
    res = invoke_skill_safe(dev, skill_name, args)
    text, err = _extract_snapshot(res)
    if err:
        return json.dumps({"error": err})
    return _truncate(text)


def invoke_skill_safe(device_id: str, skill_name: str, args: dict) -> dict:
    try:
        from webui.api.device_bridge import invoke_skill
    except Exception as exc:  # pragma: no cover - import wiring
        return {"ok": False, "error": f"device bridge unavailable: {exc}"}
    return invoke_skill(device_id, skill_name, args or {}, timeout=_CALL_TIMEOUT)


# ── schemas ──────────────────────────────────────────────────────────────────

_NAV = {
    "name": "chrome_navigate",
    "description": (
        "Open a URL in the user's REAL, visible Chrome on their Mac (their "
        "logged-in session) and return a size-capped accessibility snapshot with "
        "clickable refs (e.g. e47). Use this — NOT open_url and NOT the headless "
        "browser_* tools — to read or act on a page in the user's own browser."
    ),
    "parameters": {"type": "object",
                   "properties": {"url": {"type": "string", "description": "URL to open"}},
                   "required": ["url"]},
}
_SNAP = {
    "name": "chrome_snapshot",
    "description": ("Re-read the current page in the user's Mac Chrome as a "
                    "size-capped accessibility snapshot with clickable refs."),
    "parameters": {"type": "object", "properties": {}},
}
_CLICK = {
    "name": "chrome_click",
    "description": ("Click an element in the user's Mac Chrome by its `ref` from a "
                    "recent snapshot. Returns the resulting page snapshot."),
    "parameters": {"type": "object",
                   "properties": {
                       "element": {"type": "string", "description": "human-readable element description"},
                       "ref": {"type": "string", "description": "element ref from the snapshot, e.g. e47"}},
                   "required": ["element", "ref"]},
}
_TYPE = {
    "name": "chrome_type",
    "description": ("Type text into an element in the user's Mac Chrome (set "
                    "submit=true to press Enter). Returns the resulting snapshot."),
    "parameters": {"type": "object",
                   "properties": {
                       "element": {"type": "string"},
                       "ref": {"type": "string"},
                       "text": {"type": "string"},
                       "submit": {"type": "boolean", "description": "press Enter after typing"}},
                   "required": ["element", "ref", "text"]},
}
_KEY = {
    "name": "chrome_press_key",
    "description": "Press a key (Enter, ArrowDown, PageDown, …) in the user's Mac Chrome.",
    "parameters": {"type": "object",
                   "properties": {"key": {"type": "string"}},
                   "required": ["key"]},
}


def _h_navigate(args, **kw):
    return _chrome_call("chrome_navigate", {"url": (args or {}).get("url", "")})


def _h_snapshot(args, **kw):
    return _chrome_call("chrome_snapshot", {})


def _h_click(args, **kw):
    a = args or {}
    return _chrome_call("chrome_click", {"element": a.get("element", ""), "ref": a.get("ref", "")})


def _h_type(args, **kw):
    a = args or {}
    out = {"element": a.get("element", ""), "ref": a.get("ref", ""), "text": a.get("text", "")}
    if a.get("submit"):
        out["submit"] = True
    return _chrome_call("chrome_type", out)


def _h_press_key(args, **kw):
    return _chrome_call("chrome_press_key", {"key": (args or {}).get("key", "")})


# Explicit top-level registrations (NOT a loop — discover_builtin_tools' AST scan
# only picks up modules with a top-level ``registry.register(...)`` statement).
registry.register(name="chrome_navigate", toolset="chrome", schema=_NAV,
                  handler=_h_navigate, check_fn=_chrome_available, emoji="🌐")
registry.register(name="chrome_snapshot", toolset="chrome", schema=_SNAP,
                  handler=_h_snapshot, check_fn=_chrome_available, emoji="📸")
registry.register(name="chrome_click", toolset="chrome", schema=_CLICK,
                  handler=_h_click, check_fn=_chrome_available, emoji="🖱️")
registry.register(name="chrome_type", toolset="chrome", schema=_TYPE,
                  handler=_h_type, check_fn=_chrome_available, emoji="⌨️")
registry.register(name="chrome_press_key", toolset="chrome", schema=_KEY,
                  handler=_h_press_key, check_fn=_chrome_available, emoji="⏎")
