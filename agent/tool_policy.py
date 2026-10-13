"""What a harness node may CALL.

Every agent on a model sends one canonical tools list (sorted, the same for
every node, chat and job), so they all share the provider's prompt cache. A
node's tool setting therefore never changes that list: it is enforced when a
tool is dispatched (``agent.allowed_tool_names``) and stated in the node's turn
notes. ``None`` means every tool is allowed.
"""
from __future__ import annotations

import json


def _names_for_toolsets(toolsets) -> set:
    from tools.lazy_tools import _tool_names_for_toolsets
    return _tool_names_for_toolsets(list(toolsets) + ["devices"])


def node_tool_policy(setting):
    """``(allowed_names | None, notes_line)`` for a node's ``tools`` setting:
    ``"lean"``/``"all"`` → unrestricted, ``"none"`` → no tools, a list of
    toolset names → only those (plus the device tools and the on-demand
    search/bridge that reach the rest of an allowed group)."""
    if setting in (None, "", "lean", "all"):
        return None, ""
    if setting == "none":
        return frozenset(), "Answer without tools for this turn."
    if isinstance(setting, (list, tuple)):
        groups = [str(s) for s in setting if s]
        names = frozenset(_names_for_toolsets(groups) | {"tool_search", "tool_call"})
        return names, "Use only these tool groups this turn: " + ", ".join(groups) + "."
    return None, ""


def refusal(name: str) -> str:
    """The tool result for a call outside the node's setting."""
    return json.dumps({"error": f"The tool {name!r} is not available to this step. "
                                "Answer with what you have, or use a tool you are allowed."})


def _tool_name(tool) -> str:
    if not isinstance(tool, dict):
        return ""
    return (tool.get("function") or {}).get("name") or tool.get("name") or ""


def canonical_tools(tools):
    """``tools`` sorted by name with duplicates dropped — the byte-stable order
    every agent sends, whatever order the toolsets resolved in."""
    seen, out = set(), []
    for t in sorted(tools or [], key=_tool_name):
        name = _tool_name(t)
        if name in seen:
            continue
        seen.add(name)
        out.append(t)
    return out


def _known_tool_names() -> set:
    try:
        from tools.registry import registry
        return {e.name for e in registry._snapshot_entries()}
    except Exception:
        return set()


def _called_name(name, args) -> str:
    """The tool a call really reaches: a bridged ``tool_call`` names it inside,
    and the bridge takes a device skill's bare name ("x5_get_status") for its
    ``device_`` tool — judge the same tool it will run."""
    if name == "tool_call" and isinstance(args, dict) and isinstance(args.get("name"), str):
        inner = args["name"]
        if inner and not inner.startswith("device_"):
            from tools.lazy_tools import device_alias
            inner = device_alias(inner, _known_tool_names())
        return inner
    return name


def block_message(agent, name, args):
    """Why this call must not run on ``agent`` (``None`` when it may). Checked
    with the plugin/guardrail blocks, before anything executes (the executor
    and the claude-code engine's ``invoke_tool`` both ask)."""
    real = _called_name(name, args)
    if real == "handoff":
        wired = getattr(agent, "_handoff_wired", None)
        if wired is False:
            return "No background node is wired here, so there is nothing to hand off to. Finish the task yourself."
        if wired:
            return None  # a wired node may always hand off, whatever its tool setting
    if real == "computer_do" and getattr(agent, "_computer_node", None):
        return None  # a node wired to a Computer node may always use it
    allowed = getattr(agent, "allowed_tool_names", None)
    if allowed is None or real == "tool_search" or real in allowed:
        return None
    return json.loads(refusal(real))["error"]
