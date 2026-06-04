"""Browser device skills (A2) — drive the user's REAL, visible Chrome on this
Mac via a local Playwright MCP (extension-connected). The agent reaches these
over the proven device-bridge invoke_skill path, so no MCP-over-the-bridge.

Named ``chrome_*`` (not ``browser_*``) to stay distinct from the server's own
headless ``browser_*`` tools — these explicitly mean "the user's real Chrome."
"""
from __future__ import annotations

import os

from jc_client.skills import skill
from jc_client.browser_mcp import browser_mcp


def _snapshot_args() -> dict:
    """Optional Playwright snapshot ``depth`` (env JC_BROWSER_SNAPSHOT_DEPTH) to
    shrink the accessibility tree at the source. The char cap in browser_mcp is
    the hard bound; depth just keeps more of the page within that budget."""
    raw = os.environ.get("JC_BROWSER_SNAPSHOT_DEPTH", "").strip()
    if raw.isdigit() and int(raw) > 0:
        return {"depth": int(raw)}
    return {}


def _act_then_snapshot(action: str, args: dict) -> dict:
    """Run a Playwright action, then return a FRESH, INLINE accessibility snapshot.

    Why not just return the action's own result: Playwright MCP 0.0.75 can save a
    large post-action snapshot to a Mac-local file and return only the path — the
    agent then reads that file raw, dumping the full (uncapped) tree into context
    (one real run hit ~350k tokens). An explicit ``browser_snapshot`` with no
    ``filename`` is always returned INLINE, so browser_mcp's size cap applies."""
    mgr = browser_mcp()
    mgr.call_tool(action, args)
    return mgr.call_tool("browser_snapshot", _snapshot_args())


@skill(
    "chrome_navigate",
    "Open a URL in the user's REAL, visible Chrome on their Mac (Playwright, "
    "their logged-in session). Returns a size-capped accessibility snapshot of "
    "the page with clickable refs (e.g. e47) — you do NOT need a separate "
    "chrome_snapshot afterward. Use this — NOT open_url — whenever you then need "
    "to read or click the page.",
    {"type": "object",
     "properties": {"url": {"type": "string", "description": "URL to open"}},
     "required": ["url"]},
)
def chrome_navigate(url: str) -> dict:
    return _act_then_snapshot("browser_navigate", {"url": url})


@skill(
    "chrome_snapshot",
    "Capture a size-capped accessibility-tree snapshot of the current page in "
    "the user's Chrome, with clickable element refs (e.g. e47). chrome_navigate/"
    "chrome_click already return one, so you usually only need this to re-read a "
    "page after it changed on its own.",
    {"type": "object", "properties": {}},
)
def chrome_snapshot() -> dict:
    return browser_mcp().call_tool("browser_snapshot", _snapshot_args())


@skill(
    "chrome_click",
    "Click an element in the user's Chrome. Pass the element's human-readable "
    "description and its ref from a recent snapshot (the `[ref=eNN]` value). "
    "Returns the resulting size-capped page snapshot — no separate "
    "chrome_snapshot needed afterward.",
    {"type": "object",
     "properties": {
         "element": {"type": "string", "description": "human-readable element description"},
         "ref": {"type": "string", "description": "element ref from the snapshot, e.g. e47"}},
     "required": ["element", "ref"]},
)
def chrome_click(element: str, ref: str) -> dict:
    # Playwright MCP (>=0.0.75) takes the snapshot ref as `target`; `element`
    # is the human-readable description used only for the permission prompt.
    return _act_then_snapshot("browser_click", {"element": element, "target": ref})


@skill(
    "chrome_type",
    "Type text into an element (e.g. a search box) in the user's Chrome. Set "
    "submit=true to press Enter after typing. Returns the resulting size-capped "
    "page snapshot.",
    {"type": "object",
     "properties": {
         "element": {"type": "string"},
         "ref": {"type": "string"},
         "text": {"type": "string"},
         "submit": {"type": "boolean", "description": "press Enter after typing"}},
     "required": ["element", "ref", "text"]},
)
def chrome_type(element: str, ref: str, text: str, submit: bool = False) -> dict:
    # `target` is the snapshot ref (Playwright MCP >=0.0.75); `element` is the
    # human-readable description.
    args = {"element": element, "target": ref, "text": text}
    if submit:
        args["submit"] = True
    return _act_then_snapshot("browser_type", args)


@skill(
    "chrome_press_key",
    "Press a key (e.g. Enter, ArrowDown, PageDown) in the user's Chrome. Returns "
    "the resulting size-capped page snapshot.",
    {"type": "object",
     "properties": {"key": {"type": "string"}},
     "required": ["key"]},
)
def chrome_press_key(key: str) -> dict:
    return _act_then_snapshot("browser_press_key", {"key": key})
