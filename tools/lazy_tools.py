"""Lazy tool-schema loading (the ToolSearch pattern).

The agent normally sends EVERY tool's full JSON schema on every request, which
dominates the per-turn token floor (a trivial "hello" measured ~45k input
tokens). Here we advertise only a lean *core* set plus a ``tool_search``
meta-tool; every other tool (and all MCP tools) is listed by NAME in a cheap
system-prompt manifest, and its full schema is loaded on demand when the model
calls ``tool_search``.

Design: docs/superpowers/specs/2026-06-04-lazy-tool-loading-design.md

Key properties
--------------
* ``partition_lazy_tools`` is a pure split of the already-resolved tool defs into
  (core schemas kept, deferred manifest entries) — no registry/config access.
* ``tool_search`` is intercepted in ``agent/tool_executor.py`` (like ``memory``
  / ``delegate_task``) so ``handle_tool_search`` can mutate the live
  ``agent.tools`` directly. The registry only holds its schema + a stub handler.
* Deferred tools stay **executable** even if called before loading — dispatch
  resolves by name from the global registry (``registry.dispatch``).
"""
from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Tuple

from tools.registry import registry

# Only switch a session to lazy mode when there are at least this many tools to
# defer — below it the manifest + tool_search round-trips cost more than the
# schema savings (e.g. a subagent scoped to one small toolset).
_LAZY_MIN_DEFERRED = 6

# Imported at module top so tests can monkeypatch ``lazy_tools.load_config``.
try:  # pragma: no cover - import wiring
    from jarviscopilot_cli.config import load_config
except Exception:  # pragma: no cover
    load_config = None  # type: ignore


# ── config gating ────────────────────────────────────────────────────────────

def lazy_tools_enabled() -> bool:
    """True when ``agent.lazy_tools`` is on (default True)."""
    try:
        cfg = (load_config() or {}).get("agent", {}) or {} if load_config else {}
        return bool(cfg.get("lazy_tools", True))
    except Exception:
        return True


def get_lazy_core_names() -> set:
    """The always-loaded core tool names. ``agent.lazy_tools_core`` overrides the
    built-in lean list; ``tool_search`` is always included. Kanban workers
    (``HERMES_KANBAN_TASK`` set) keep their lifecycle tools in core — their first
    action is a kanban call and the worker guidance gates on them being present."""
    from toolsets import _LAZY_CORE_TOOLS
    override: List[str] = []
    try:
        if load_config:
            override = ((load_config() or {}).get("agent", {}) or {}).get("lazy_tools_core") or []
    except Exception:
        override = []
    names = set(override) if override else set(_LAZY_CORE_TOOLS)
    names.add("tool_search")
    if os.environ.get("HERMES_KANBAN_TASK"):
        try:
            from toolsets import resolve_toolset
            names.update(resolve_toolset("kanban"))
        except Exception:
            pass
    return names


# ── partition + manifest ─────────────────────────────────────────────────────

def _first_sentence(desc: str) -> str:
    """First line, first sentence — a compact one-liner for the manifest."""
    if not desc:
        return ""
    line = desc.strip().split("\n", 1)[0]
    return line.split(". ", 1)[0].strip()


def partition_lazy_tools(full_defs: List[Dict[str, Any]], core_names: set
                         ) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """Split fully-resolved OpenAI-format tool defs into
    ``(core schemas kept, deferred manifest entries)``. Pure: no registry/config.

    Deferred entries are ``{"name", "description"}`` (one-line description).
    """
    core: List[Dict[str, Any]] = []
    deferred: List[Dict[str, str]] = []
    for d in full_defs:
        fn = d.get("function", {}) or {}
        name = fn.get("name")
        if not name:
            continue
        if name in core_names:
            core.append(d)
        else:
            deferred.append({"name": name, "description": _first_sentence(fn.get("description") or "")})
    return core, deferred


def build_manifest_text(deferred: List[Dict[str, str]]) -> str:
    """Render the deferred-tools manifest, grouped by toolset, one
    ``- name — desc`` line each. Returns ``""`` when nothing is deferred.

    Toolset comes from the entry if present, else a registry lookup (so a pure
    ``partition_lazy_tools`` output is enriched here without the caller needing
    the registry)."""
    if not deferred:
        return ""
    by_ts: Dict[str, List[Dict[str, str]]] = {}
    for e in deferred:
        ts = e.get("toolset") or registry.get_toolset_for_tool(e["name"]) or "other"
        by_ts.setdefault(ts, []).append(e)
    lines = [
        "# Deferred tools",
        "These tools are available but their parameters are not loaded yet. Call "
        "tool_search to load a tool's schema before using it if you are unsure of "
        "its arguments.",
    ]
    for ts in sorted(by_ts):
        lines.append(f"\n## {ts}")
        for e in sorted(by_ts[ts], key=lambda x: x["name"]):
            desc = e.get("description") or ""
            lines.append(f"- {e['name']}" + (f" — {desc}" if desc else ""))
    return "\n".join(lines)


# ── partition application + availability (mid-session safe) ──────────────────

def apply_lazy_partition(agent) -> None:
    """Partition ``agent.tools`` into a lean advertised core (plus any tools
    already loaded this session) and a deferred manifest, mutating the agent in
    place. Idempotent and safe to call at init AND after any mid-session rebuild
    of ``agent.tools`` (MCP reload, ACP registration) — without this, those
    rebuilds re-inflate the tool set and drop the manifest + loaded tools.

    No-op when lazy is disabled or there is little to defer. Always records
    ``agent._lazy_all_tool_names`` (advertised + deferred) so guidance can gate on
    tool *availability* rather than current advertisement."""
    if getattr(agent, "_lazy_loaded_tools", None) is None:
        agent._lazy_loaded_tools = set()
    if not hasattr(agent, "_lazy_tools_manifest"):
        agent._lazy_tools_manifest = ""
    if not lazy_tools_enabled() or not getattr(agent, "tools", None):
        return
    core_names = get_lazy_core_names() | set(agent._lazy_loaded_tools)
    core, deferred = partition_lazy_tools(agent.tools, core_names)
    agent._lazy_all_tool_names = (
        {c.get("function", {}).get("name") for c in core}
        | {d["name"] for d in deferred}
    )
    agent._lazy_all_tool_names.discard(None)
    # Fingerprint of the available toolset — used to invalidate a resumed
    # session's STORED system prompt (and its frozen manifest) when the set of
    # registered tools changes (e.g. chrome_* added), so existing conversations
    # pick up new tools instead of reusing a stale manifest forever. Stable per
    # toolset (changes only on register/deregister), so it does NOT cause
    # per-turn cache churn. See conversation_loop._restore_or_build_system_prompt.
    import hashlib
    agent._toolset_fingerprint = hashlib.sha1(
        ",".join(sorted(agent._lazy_all_tool_names)).encode("utf-8")
    ).hexdigest()[:16]
    if len(deferred) < _LAZY_MIN_DEFERRED:
        return  # not worth the manifest + tool_search round-trips
    agent.tools = core
    agent._lazy_tools_manifest = build_manifest_text(deferred)
    agent.valid_tool_names = {c.get("function", {}).get("name") for c in core}
    agent.valid_tool_names.discard(None)


def available_tool_names(agent) -> set:
    """All tools the agent can use this session — advertised tools PLUS deferred
    ones (loadable via tool_search). Use this (not ``valid_tool_names``) to gate
    behavioral guidance, so guidance for a deferred tool still appears. Falls back
    to ``valid_tool_names`` for non-lazy agents."""
    base = set(getattr(agent, "valid_tool_names", None) or set())
    allnames = getattr(agent, "_lazy_all_tool_names", None)
    return (base | set(allnames)) if allnames else base


# ── query resolution ─────────────────────────────────────────────────────────

def resolve_query(query: str, candidate_names: List[str]) -> List[str]:
    """``select:a,b`` → those exact names (in the order given, dropping unknown).
    Otherwise a keyword match over names (case-insensitive, ranked by hit count)."""
    q = (query or "").strip()
    candidates = list(candidate_names)
    if q.lower().startswith("select:"):
        wanted = [n.strip() for n in q[len("select:"):].split(",") if n.strip()]
        cset = set(candidates)
        return [n for n in wanted if n in cset]
    terms = [t for t in q.lower().replace("_", " ").split() if t]
    if not terms:
        return []
    scored = []
    for n in candidates:
        hay = n.lower().replace("_", " ")
        hits = sum(1 for t in terms if t in hay)
        if hits:
            scored.append((hits, n))
    scored.sort(key=lambda x: (-x[0], x[1]))
    return [n for _, n in scored]


# ── tool_search: schema, guidance, handler ───────────────────────────────────

LAZY_TOOLS_GUIDANCE = (
    "Your tools are loaded lazily to save context. A lean core set is fully "
    "available now; every other tool is listed by NAME in the 'Deferred tools' "
    "section below. IMPORTANT: a tool listed there IS available to you — it is "
    "NOT unavailable. If a task needs a tool that is named in 'Deferred tools' "
    "but not in your active tool list (e.g. the chrome_* real-Mac-Chrome tools), "
    "do NOT tell the user it's unavailable and do NOT refuse — instead FIRST call "
    "tool_search to load it, THEN call it. Pass `select:tool_a,tool_b` for exact "
    "tools you already know the name of, or a few keywords to find the right one. "
    "Loaded tools stay available for the rest of the session. tool_search only "
    "loads AGENT tools (the ones in the Deferred tools list). A paired "
    "phone/tablet's device skills (e.g. send_sms, run_shortcut) are NOT agent "
    "tools — invoke those through the devices skill, not tool_search."
)

TOOL_SEARCH_SCHEMA = {
    "name": "tool_search",
    "description": (
        "Load the full parameter schemas for deferred tools so you can call them. "
        "Use `select:name1,name2` to load specific tools by exact name (from the "
        "Deferred tools list), or a short keyword query (e.g. 'navigate browser', "
        "'send email') to find matching tools. Returns the loaded tools' schemas; "
        "they stay callable for the rest of the session."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "`select:a,b` for exact tool names, or keywords to search.",
            },
        },
        "required": ["query"],
    },
}

_MAX_SEARCH_RESULTS = 12


def handle_tool_search(agent, args: dict) -> str:
    """Resolve the query to tool names, load their schemas, and promote them into
    the live ``agent.tools`` / ``agent.valid_tool_names`` so the provider lets the
    model call them. Returns a JSON string with the loaded names + schemas.

    Intercepted in ``agent/tool_executor.py`` (needs ``agent`` state)."""
    query = (args or {}).get("query", "")
    all_names = [e.name for e in registry._snapshot_entries()]
    matches = resolve_query(query, all_names)
    if not matches:
        return json.dumps({"loaded": [], "note": f"No tools matched {query!r}. "
                           "Check the Deferred tools list and try `select:exact_name`."})
    capped = len(matches) > _MAX_SEARCH_RESULTS
    matches = matches[:_MAX_SEARCH_RESULTS]

    # get_definitions applies check_fn gating — unavailable tools are silently
    # skipped here (they genuinely can't be used).
    defs = registry.get_definitions(set(matches))
    advertised = {t.get("function", {}).get("name") for t in agent.tools}
    for d in defs:
        nm = d.get("function", {}).get("name")
        if nm and nm not in advertised:
            agent.tools.append(d)
            agent.valid_tool_names.add(nm)
            advertised.add(nm)

    loaded = [d["function"]["name"] for d in defs]
    # Remember what we loaded so a mid-session re-partition (MCP reload, ACP)
    # keeps these advertised instead of dropping them back to the manifest.
    if getattr(agent, "_lazy_loaded_tools", None) is None:
        agent._lazy_loaded_tools = set()
    agent._lazy_loaded_tools.update(loaded)
    out: Dict[str, Any] = {"loaded": loaded, "schemas": [d["function"] for d in defs]}
    unavailable = [m for m in matches if m not in set(loaded)]
    if unavailable:
        out["unavailable"] = unavailable
    if capped:
        out["note"] = (f"More than {_MAX_SEARCH_RESULTS} tools matched; showing the "
                       f"top {_MAX_SEARCH_RESULTS}. Refine with `select:exact_name`.")
    return json.dumps(out)


def _check_lazy_tools() -> bool:
    """check_fn: tool_search only appears when lazy loading is enabled."""
    return lazy_tools_enabled()


def _tool_search_stub(args, **kw):
    # Real handling is intercepted in agent/tool_executor.py (needs agent state).
    return json.dumps({"error": "tool_search must be handled by the agent loop"})


registry.register(
    name="tool_search",
    toolset="lazy_tools",
    schema=TOOL_SEARCH_SCHEMA,
    handler=_tool_search_stub,
    check_fn=_check_lazy_tools,
    emoji="🔎",
)
