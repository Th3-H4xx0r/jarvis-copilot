"""Prompt-cache breakpoints for providers that need explicit markers.

The shared layout (docs/superpowers/specs/2026-10-11-shared-prompt-cache-design.md):
every agent on a model sends the same tools, cached on their own breakpoint and
shared across chats, harness nodes and jobs; then the system prompt — stable
block plus volatile tail (memory, profile, date, model line, chat guidance) —
cached through its END, because that tail is the same for every new chat on a
day (a changed tail re-sends only the system block, never the tools). Up to 4:

    tools (1)  →  whole system prompt (1)  →  last 2 messages
    (no tools: the last 3 messages; old callers without ``system_parts``:
     system + last 3, as before)

Retention is generic (``standard`` | ``long``); here ``long`` means the 1-hour
tier on the tools, the system prompt and the older tail marker, and 5 minutes
on the newest message (a 1-hour entry must come before any 5-minute one).
Providers that cache automatically never call this.

Pure functions -- no class state, no AIAgent dependency.
"""

import copy
from typing import Any, Dict, List


def _apply_cache_marker(msg: dict, cache_marker: dict, native_anthropic: bool = False) -> None:
    """Add cache_control to a single message, handling all format variations."""
    role = msg.get("role", "")
    content = msg.get("content")

    if role == "tool":
        if native_anthropic:
            msg["cache_control"] = cache_marker
        return

    if content is None or content == "":
        msg["cache_control"] = cache_marker
        return

    if isinstance(content, str):
        msg["content"] = [
            {"type": "text", "text": content, "cache_control": cache_marker}
        ]
        return

    if isinstance(content, list) and content:
        last = content[-1]
        if isinstance(last, dict):
            last["cache_control"] = cache_marker


def _build_marker(ttl: str) -> Dict[str, str]:
    """Build a cache_control marker dict for the given TTL ('5m' or '1h')."""
    marker: Dict[str, str] = {"type": "ephemeral"}
    if ttl == "1h":
        marker["ttl"] = "1h"
    return marker


def marker_retention(agent) -> str:
    """The retention the cache MARKERS use for ``agent``: "long" (1-hour
    markers) only where the endpoint takes them — native Anthropic and
    OpenRouter; a third-party gateway speaking the protocol gets the 5-minute
    tier rather than a field it may reject."""
    if getattr(agent, "_cache_retention", "standard") != "long":
        return "standard"
    base = str(getattr(agent, "base_url", "") or "").lower()
    if "openrouter.ai" in base:
        return "long"
    if getattr(agent, "api_mode", None) == "anthropic_messages":
        try:
            from agent.anthropic_adapter import _is_third_party_anthropic_endpoint
            if not _is_third_party_anthropic_endpoint(getattr(agent, "_anthropic_base_url", None)):
                return "long"
        except Exception:
            pass
    return "standard"


def tool_cache_marker(retention: str = "standard") -> Dict[str, str]:
    """The marker for the last tool: the head of every agent's prompt."""
    return _build_marker("1h" if retention == "long" else "5m")


def _split_system(msg: dict, system_parts, marker: dict) -> bool:
    """Send the system prompt as [stable, volatile] text blocks, cached through
    the volatile one, when ``system_parts`` really is this prompt; False leaves
    it to the caller."""
    if not isinstance(system_parts, dict):
        return False
    stable = system_parts.get("stable") or ""
    volatile = system_parts.get("volatile") or ""
    content = msg.get("content")
    if not stable or not isinstance(content, str):
        return False
    if content != (stable + "\n\n" + volatile if volatile else stable):
        return False
    # One marker, after the volatile tail: it is the same for every new chat on
    # a day (memory, profile, date, chat guidance), so caching only the stable
    # block made each new chat's first message re-read ~8k tokens. The tools
    # keep their own marker, so a changed tail re-reads just the system block.
    blocks = [{"type": "text", "text": stable}]
    if volatile:
        blocks.append({"type": "text", "text": volatile})
    blocks[-1]["cache_control"] = marker
    msg["content"] = blocks
    return True


def apply_anthropic_cache_control(
    api_messages: List[Dict[str, Any]],
    cache_ttl: str = "5m",
    native_anthropic: bool = False,
    *,
    system_parts: Dict[str, str] | None = None,
    retention: str | None = None,
    reserve_for_tools: bool = False,
) -> List[Dict[str, Any]]:
    """Place up to 4 cache_control breakpoints on a deep copy of
    ``api_messages`` (see the module docstring for the layout).

    ``reserve_for_tools`` leaves one breakpoint for the caller's tools marker
    (``tool_cache_marker``). Without ``retention`` every marker uses
    ``cache_ttl`` (the old single-TTL behaviour).
    """
    messages = copy.deepcopy(api_messages)
    if not messages:
        return messages

    if retention in ("standard", "long"):
        head = _build_marker("1h" if retention == "long" else "5m")
        older = head
        newest = _build_marker("5m")
    else:
        head = older = newest = _build_marker(cache_ttl)

    breakpoints_used = 1 if reserve_for_tools else 0

    if messages[0].get("role") == "system":
        if not _split_system(messages[0], system_parts, head):
            _apply_cache_marker(messages[0], head, native_anthropic=native_anthropic)
        breakpoints_used += 1

    remaining = max(0, 4 - breakpoints_used)
    non_sys = [i for i in range(len(messages)) if messages[i].get("role") != "system"]
    tail = non_sys[-remaining:] if remaining else []
    for n, idx in enumerate(tail):
        marker = newest if n == len(tail) - 1 else older
        _apply_cache_marker(messages[idx], marker, native_anthropic=native_anthropic)

    return messages
