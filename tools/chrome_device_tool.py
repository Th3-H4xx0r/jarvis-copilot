"""Direct ``chrome_*`` AGENT tools for driving the user's real, visible Chrome on
a paired Mac (A2 "speed" path).

The Mac client advertises ``chrome_*`` **device skills** (desktop_client/.../
skills/browser.py) that drive a real Playwright-extension Chrome. Previously the
agent reached them the slow way — read the devices SKILL.md, shell out to
``devices.py invoke`` through the terminal, parse the output. These tools wrap the
same device skills as first-class agent tools and truncate the snapshot
server-side (mirrors the headless browser tool).

IMPORTANT topology note: the device bridge's connection registry lives in the
**webui** process; the agent generally runs in a **separate** process and cannot
see it in-memory. So — exactly like ``devices.py`` — these tools reach the device
through the webui's localhost REST API, host-signed with ``.signing_key`` (no
cookie needed). In-process ``invoke_skill`` would silently find zero devices.

Under lazy tool-loading these are deferred (manifest) and surface only when a
chrome-capable device is online (``check_fn``); the agent tool_searches them once,
then drives Chrome with direct tool calls — no terminal, no SKILL.md round-trip.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional, Tuple

from tools.registry import registry

_CALL_TIMEOUT = 90.0           # device-side budget for a slow page load
_RESOLVE_TIMEOUT = 5.0         # short — runs inside check_fn every ~30s
_SNAPSHOT_SKILL = "chrome_navigate"  # marker skill a chrome-capable device advertises


# ── webui REST plumbing (mirrors skills/jarviscopilot/devices/scripts/devices.py) ──

def _state_dir() -> Path:
    env = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / ".jarviscopilot" / "webui").resolve()


def _webui_origin() -> str:
    scheme = "https" if os.environ.get("HERMES_WEBUI_TLS_CERT") else "http"
    port = os.environ.get("HERMES_WEBUI_PORT", "8787")
    host = os.environ.get("HERMES_WEBUI_HOST", "127.0.0.1")
    return f"{scheme}://{host}:{port}"


def _host_signature(method: str, path: str) -> Optional[str]:
    """``<ts>.<hmac>`` host signature (matches webui auth._check_host_signature).
    None if the signing key isn't readable."""
    try:
        sk = (_state_dir() / ".signing_key").read_bytes()
        ts = int(time.time())
        msg = f"{method.upper()}\n{path}\n{ts}".encode("utf-8")
        sig = hmac.new(sk, msg, hashlib.sha256).hexdigest()
        return f"{ts}.{sig}"
    except Exception:
        return None


def _api_request(method: str, path: str, body: Optional[dict] = None,
                 timeout: float = 10.0) -> dict:
    """Host-signed request to the local webui. Returns parsed JSON, or
    ``{"_error": "..."}`` on transport failure."""
    url = _webui_origin() + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json", "X-Requested-With": "fetch"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    sig = _host_signature(method, path)
    if sig:
        headers["X-JC-Host-Sig"] = sig
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    ctx = None
    if url.startswith("https://"):
        import ssl
        ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read().decode("utf-8", errors="replace") or "{}"
            try:
                return json.loads(raw)
            except Exception:
                return {"_error": "bad json from webui"}
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8", errors="replace") or "{}")
        except Exception:
            return {"_error": f"http {e.code}"}
    except Exception as e:
        return {"_error": str(e)}


# ── device resolution ────────────────────────────────────────────────────────

def _resolve_chrome_device() -> Optional[str]:
    """device_id of an online device advertising the chrome skills, else None.
    Asks the webui (``GET /api/devices/skills``) so it works cross-process."""
    data = _api_request("GET", "/api/devices/skills", timeout=_RESOLVE_TIMEOUT)
    if not isinstance(data, dict) or data.get("_error"):
        return None
    for s in data.get("skills", []) or []:
        if isinstance(s, dict) and s.get("name") == _SNAPSHOT_SKILL and s.get("device_id"):
            return str(s["device_id"])
    return None


def invoke_skill_safe(device_id: str, skill_name: str, args: dict) -> dict:
    """Invoke a device skill over the webui REST API. Returns the webui's
    ``{ok,result}`` (or ``{ok:False,error}``)."""
    resp = _api_request("POST", "/api/devices/skills/invoke", body={
        "device_id": device_id,
        "skill": skill_name,
        "args": args or {},
        "timeout": _CALL_TIMEOUT,
    }, timeout=_CALL_TIMEOUT + 5)
    if resp.get("_error"):
        return {"ok": False, "error": resp["_error"]}
    return resp


# ── result handling ──────────────────────────────────────────────────────────

def _extract_snapshot(invoke_result: dict) -> Tuple[str, Optional[str]]:
    """Unwrap the webui's ``{ok,result}`` AND the device skill's own inner
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
        if len(text) <= 8000:
            return text
        return text[:8000].rsplit("\n", 1)[0] + "\n[... snapshot truncated]"


def _chrome_call(skill_name: str, args: dict) -> str:
    dev = _resolve_chrome_device()
    if not dev:
        return json.dumps({"error": "No Mac with Chrome is paired and online. "
                           "Ensure the JarvisCopilot Mac client is running and the "
                           "Playwright Chrome extension is connected."})
    text, err = _extract_snapshot(invoke_skill_safe(dev, skill_name, args))
    if err:
        return json.dumps({"error": err})
    return _truncate(text)


# ── schemas + handlers ───────────────────────────────────────────────────────

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


# Registered WITHOUT a check_fn — always present (deferred under lazy loading, so
# ~5 cheap manifest lines, not full schemas). A probe-based check_fn proved flaky
# (cross-process webui probe timing), which silently hid the tools entirely. Now
# they always surface; the handler returns a clean "no Mac online" error when
# _resolve_chrome_device() finds nothing. Explicit top-level calls (NOT a loop —
# discover_builtin_tools' AST scan only sees top-level registry.register(...)).
registry.register(name="chrome_navigate", toolset="chrome", schema=_NAV,
                  handler=_h_navigate, emoji="🌐")
registry.register(name="chrome_snapshot", toolset="chrome", schema=_SNAP,
                  handler=_h_snapshot, emoji="📸")
registry.register(name="chrome_click", toolset="chrome", schema=_CLICK,
                  handler=_h_click, emoji="🖱️")
registry.register(name="chrome_type", toolset="chrome", schema=_TYPE,
                  handler=_h_type, emoji="⌨️")
registry.register(name="chrome_press_key", toolset="chrome", schema=_KEY,
                  handler=_h_press_key, emoji="⏎")
