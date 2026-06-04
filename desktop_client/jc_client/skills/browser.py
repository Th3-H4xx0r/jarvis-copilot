"""Browser device skills (A2) — drive the user's REAL, visible Chrome on this
Mac via a local Playwright MCP (extension-connected). The agent reaches these
over the proven device-bridge invoke_skill path, so no MCP-over-the-bridge.

Named ``chrome_*`` (not ``browser_*``) to stay distinct from the server's own
headless ``browser_*`` tools — these explicitly mean "the user's real Chrome."
"""
from __future__ import annotations

from jc_client.skills import skill
from jc_client.browser_mcp import browser_mcp


@skill(
    "chrome_navigate",
    "Open a URL in the user's REAL, visible Chrome on their Mac (Playwright, "
    "their logged-in session). Returns the page title and an accessibility "
    "snapshot with clickable refs when available; if the result has no refs, "
    "call chrome_snapshot once to get them. Use this — NOT open_url — whenever "
    "you then need to read or click the page.",
    {"type": "object",
     "properties": {"url": {"type": "string", "description": "URL to open"}},
     "required": ["url"]},
)
def chrome_navigate(url: str) -> dict:
    return browser_mcp().call_tool("browser_navigate", {"url": url})


@skill(
    "chrome_snapshot",
    "Capture an accessibility-tree snapshot of the current page in the user's "
    "Chrome, with clickable element refs (e.g. e47). Call this before clicking "
    "or typing so you have refs to target.",
    {"type": "object", "properties": {}},
)
def chrome_snapshot() -> dict:
    return browser_mcp().call_tool("browser_snapshot", {})


@skill(
    "chrome_click",
    "Click an element in the user's Chrome. Pass the element's human-readable "
    "description and its ref from a recent snapshot (the `[ref=eNN]` value). "
    "Returns the resulting page snapshot — no separate chrome_snapshot needed "
    "afterward.",
    {"type": "object",
     "properties": {
         "element": {"type": "string", "description": "human-readable element description"},
         "ref": {"type": "string", "description": "element ref from the snapshot, e.g. e47"}},
     "required": ["element", "ref"]},
)
def chrome_click(element: str, ref: str) -> dict:
    # Playwright MCP (>=0.0.75) takes the snapshot ref as `target`; `element`
    # is the human-readable description used only for the permission prompt.
    return browser_mcp().call_tool("browser_click", {"element": element, "target": ref})


@skill(
    "chrome_type",
    "Type text into an element (e.g. a search box) in the user's Chrome. Set "
    "submit=true to press Enter after typing.",
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
    return browser_mcp().call_tool("browser_type", args)


@skill(
    "chrome_press_key",
    "Press a key (e.g. Enter, ArrowDown, PageDown) in the user's Chrome.",
    {"type": "object",
     "properties": {"key": {"type": "string"}},
     "required": ["key"]},
)
def chrome_press_key(key: str) -> dict:
    return browser_mcp().call_tool("browser_press_key", {"key": key})
