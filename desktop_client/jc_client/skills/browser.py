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
    "their logged-in session). Returns the page title + a snapshot. Use this — "
    "NOT open_url — whenever you then need to read or click the page.",
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
    "description and its ref from a recent chrome_snapshot.",
    {"type": "object",
     "properties": {
         "element": {"type": "string", "description": "human-readable element description"},
         "ref": {"type": "string", "description": "element ref from the snapshot, e.g. e47"}},
     "required": ["element", "ref"]},
)
def chrome_click(element: str, ref: str) -> dict:
    return browser_mcp().call_tool("browser_click", {"element": element, "ref": ref})


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
    args = {"element": element, "ref": ref, "text": text}
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
