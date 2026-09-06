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
import logging
import os
from typing import Any, Dict, List, Tuple

from tools.registry import registry

logger = logging.getLogger(__name__)

# Only switch a session to lazy mode when there are at least this many tools to
# defer — below it the manifest + tool_search round-trips cost more than the
# schema savings (e.g. a subagent scoped to one small toolset).
_LAZY_MIN_DEFERRED = 6

# ── native (server-side) tool search — plan 2.3 ──────────────────────────────
# Anthropic hosts the tool search itself: every non-core tool is sent with
# ``defer_loading: true`` (schema present in the request body but NOT in the
# billed prefix) and the model pulls the ones it needs through the BM25 search
# tool below, in-request — no extra client round trip, and the tool list stays
# byte-stable across turns so the prompt cache keeps hitting.
ANTHROPIC_TOOL_SEARCH_TYPE = "tool_search_tool_bm25_20251119"
ANTHROPIC_TOOL_SEARCH_NAME = "tool_search_tool_bm25"

# Always loaded (never deferred) on the fast lane: the handful of tools a turn
# is most likely to need immediately.  The device tools are added on top of this
# by toolset name — see ``NATIVE_ALWAYS_LOADED_TOOLSETS``.  plan 2.3
NATIVE_ALWAYS_LOADED_TOOLS = (
    "terminal", "read_file", "write_file", "web_search", "memory",
    # The system prompt tells the model to load a skill with skill_view(name)
    # and to ask with clarify — deferring those strands it (observed: "missing
    # tool_search for skills" → no morning brief). They're tiny schemas.
    "skills_list", "skill_view", "clarify", "todo",
    # plan 2.5 — the fast lane's escape hatch. Deferring it would mean the small
    # model has to run a tool search just to admit it needs the big one.
    "escalate",
)
# Toolsets whose tools are never deferred.  Looked up in the live registry at
# REQUEST-BUILD time (not import time) — WS-C registers tools/device_skill_tools
# dynamically as devices connect, so an import-time snapshot would be empty.
NATIVE_ALWAYS_LOADED_TOOLSETS = ("devices",)

# Fine-grained tool streaming (plan 2.4): device tool arguments stream token by
# token so ``open_app{"name":"Safari"}`` is complete — and dispatchable — before
# the model finishes its sentence.  No beta header; the field lives on the tool
# definition.
EAGER_STREAMING_TOOLSETS = ("devices",)

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


def native_tool_search_enabled() -> bool:
    """True when ``tools.deferred`` is on (default True) — plan 2.3."""
    try:
        cfg = (load_config() or {}).get("tools", {}) or {} if load_config else {}
        return bool(cfg.get("deferred", True))
    except Exception:
        return True


def _tool_names_for_toolsets(toolsets) -> set:
    """Live registry lookup of every tool name in ``toolsets``.

    Deliberately queried on each call: device tools are registered/deregistered
    as devices pair and disconnect, and the module that defines them may not
    even be importable when this module is first imported.
    """
    names: set = set()
    for ts in toolsets:
        try:
            names.update(registry.get_tool_names_for_toolset(ts))
        except Exception:
            logger.debug("toolset lookup failed for %r", ts, exc_info=True)
    return names


def uses_native_tool_search(agent) -> bool:
    """True when this agent talks to a NATIVE Anthropic endpoint that supports
    server-side tool search — the only place ``defer_loading`` is understood.

    Third-party Anthropic-compatible gateways (Kimi /coding, MiniMax, DeepSeek,
    Azure Foundry, …) speak the Messages protocol but reject the field, so they
    keep the in-repo ``tool_search`` round trip.
    """
    try:
        if getattr(agent, "api_mode", None) != "anthropic_messages":
            return False
        if not native_tool_search_enabled():
            return False
        base_url = getattr(agent, "_anthropic_base_url", None)
        from agent.anthropic_adapter import _is_third_party_anthropic_endpoint
        return not _is_third_party_anthropic_endpoint(base_url)
    except Exception:
        return False


def build_native_deferred_tools(anthropic_tools: List[Dict[str, Any]],
                                *, drop_in_repo_search: bool = True,
                                ) -> List[Dict[str, Any]]:
    """Shape an Anthropic-format tool list for server-side tool search (plan 2.3)
    and eager device-arg streaming (plan 2.4).

    * device tools (toolset ``devices``) + ``NATIVE_ALWAYS_LOADED_TOOLS`` stay
      fully loaded; device tools also get ``eager_input_streaming: true``
    * every other tool gets ``defer_loading: true``
    * the BM25 ``tool_search`` server tool is appended (never deferred)
    * the in-repo ``tool_search`` meta-tool is dropped — the server-side search
      replaces it, and leaving both in place invites the model to burn a turn on
      the dead-end one. Pass ``drop_in_repo_search=False`` when a client-side
      manifest is still live in the system prompt: that manifest TELLS the model
      to call ``tool_search``, so removing the tool would strand it.

    Pure: returns a new list, never mutates the input. Idempotent.
    """
    if not anthropic_tools:
        return list(anthropic_tools or [])

    always_loaded = set(NATIVE_ALWAYS_LOADED_TOOLS) | _tool_names_for_toolsets(
        NATIVE_ALWAYS_LOADED_TOOLSETS
    )
    eager = _tool_names_for_toolsets(EAGER_STREAMING_TOOLSETS)

    out: List[Dict[str, Any]] = []
    loaded_count = 0
    for tool in anthropic_tools:
        if not isinstance(tool, dict):
            out.append(tool)
            continue
        if tool.get("type") == ANTHROPIC_TOOL_SEARCH_TYPE:
            continue  # re-appended below, so shaping stays idempotent
        name = tool.get("name")
        if name == "tool_search" and drop_in_repo_search:
            continue
        shaped = dict(tool)
        if name in always_loaded:
            shaped.pop("defer_loading", None)
            loaded_count += 1
            if name in eager:
                shaped["eager_input_streaming"] = True
        else:
            shaped["defer_loading"] = True
        out.append(shaped)

    # The API rejects a request where EVERY tool is deferred ("All tools have
    # defer_loading set"). Keep the first one loaded when nothing else is.
    if loaded_count == 0:
        for shaped in out:
            if isinstance(shaped, dict) and shaped.get("defer_loading"):
                shaped.pop("defer_loading", None)
                break

    out.append({"type": ANTHROPIC_TOOL_SEARCH_TYPE,
                "name": ANTHROPIC_TOOL_SEARCH_NAME})
    return out


def apply_native_tool_search(api_kwargs: Dict[str, Any], agent=None) -> Dict[str, Any]:
    """In-place shaping of a built Anthropic request. Returns the same dict.

    Feature-detects rather than crashes: any failure leaves the request exactly
    as it was (the un-deferred full tool list still works, it is only fatter).
    """
    try:
        tools = api_kwargs.get("tools")
        if tools:
            # If a client-side deferred-tools manifest is live in the system
            # prompt (agent init ran before api_mode was resolvable, a resumed
            # session, …), keep the in-repo tool_search so the manifest's
            # instructions still have something to call.
            # Always keep the in-repo tool_search as well: the system prompt's
            # guidance ("load it with tool_search") is emitted from several
            # places, not only the manifest, and a model that can't find the
            # tool it was told to call silently gives up on the task
            # (observed: skipped the morning-brief skill). One occasional
            # redundant round trip beats a stranded turn.
            api_kwargs["tools"] = build_native_deferred_tools(
                tools, drop_in_repo_search=False,
            )
    except Exception:
        _warn_once("native tool-search shaping failed; sending the full tool list")
    return api_kwargs


_warned: set = set()


def _warn_once(message: str) -> None:
    if message in _warned:
        return
    _warned.add(message)
    logger.warning("%s", message, exc_info=True)


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
    # plan 2.5 — `escalate` must never be deferred: it is how the fast model
    # says "this is beyond me". Its own check_fn keeps it out of the tool list
    # entirely when no fast lane is configured, so this costs nothing otherwise.
    names.add("escalate")
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

def _routes_through_structured_engine(agent) -> bool:
    """True when this agent runs through the claude-code STRUCTURED (MCP) engine.

    That engine drives an entire turn with a FIXED native tool list registered up
    front (claude calls tools via the MCP bridge), so it has no working way to pull
    a deferred tool's schema mid-turn: ``tool_search`` isn't intercepted on the
    structured ``_invoke_tool`` path (it hits the registry stub → an error result),
    and even if it were, mutating ``agent.tools`` can't add a tool to an
    already-started CLI turn. Lazy partitioning would therefore make every deferred
    tool (headless ``browser_*``, messaging, …) PERMANENTLY unreachable to
    claude-code, so we skip it for this engine and hand claude the full tool set.

    The text-shim path (``HERMES_CLAUDE_CODE_STRUCTURED=0``) and every other
    provider run the normal executor loop, where ``tool_search`` works — they keep
    lazy loading."""
    try:
        if getattr(agent, "provider", "") != "claude-code":
            return False
        from agent.claude_code_structured import structured_enabled
        return bool(structured_enabled())
    except Exception:
        return False


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
    if uses_native_tool_search(agent):
        # plan 2.3 — Anthropic runs the tool search server-side. Hand the model
        # the WHOLE tool set (schemas are shaped with defer_loading at
        # request-build time, so they cost nothing in the billed prefix) and drop
        # the in-repo tool_search meta-tool + manifest: two competing search
        # mechanisms would just waste a turn on the client-side one.
        agent.tools = [
            t for t in agent.tools
            if (t.get("function", {}) or {}).get("name") != "tool_search"
        ]
        agent.valid_tool_names = {
            (t.get("function", {}) or {}).get("name") for t in agent.tools
        }
        agent.valid_tool_names.discard(None)
        agent._lazy_all_tool_names = set(agent.valid_tool_names)
        agent._lazy_tools_manifest = ""
        import hashlib
        agent._toolset_fingerprint = hashlib.sha1(
            ",".join(sorted(agent._lazy_all_tool_names)).encode("utf-8")
        ).hexdigest()[:16]
        return
    if _routes_through_structured_engine(agent):
        # Full native tool set — claude calls every tool (browser_* included)
        # directly. Drop the now-pointless tool_search meta-tool so the model
        # doesn't waste a turn on a dead-end path, and leave the manifest empty so
        # no lazy guidance / "Deferred tools" section is injected (both are gated on
        # _lazy_tools_manifest being non-empty). See _routes_through_structured_engine.
        agent.tools = [
            t for t in agent.tools
            if (t.get("function", {}) or {}).get("name") != "tool_search"
        ]
        agent.valid_tool_names = {
            (t.get("function", {}) or {}).get("name") for t in agent.tools
        }
        agent.valid_tool_names.discard(None)
        agent._lazy_all_tool_names = set(agent.valid_tool_names)
        agent._lazy_tools_manifest = ""
        return
    core_names = get_lazy_core_names() | set(agent._lazy_loaded_tools)
    # Device tools are never deferred on any provider (voice-first: "open
    # directions" must be one call, not tool_search then the call).
    core_names |= _tool_names_for_toolsets(NATIVE_ALWAYS_LOADED_TOOLSETS)
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
    # A manifest without a reachable tool_search strands every deferred tool
    # ("Tool 'tool_search' does not exist"). A mid-session rebuild of
    # agent.tools can drop it (its check_fn re-reads config), so re-add the
    # schema here rather than trust the registry pass.
    if not any((c.get("function", {}) or {}).get("name") == "tool_search" for c in core):
        core.append({"type": "function", "function": TOOL_SEARCH_SCHEMA})
        _warn_once("tool_search was missing from the advertised core; re-added")
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


def load_all_deferred(agent) -> int:
    """Promote EVERY deferred tool into the live ``agent.tools`` — the voice
    bridge does this for its turns: a spoken request must be one tool call, not
    a tool_search round trip first. Returns how many tools were added. Leaves
    the manifest in place (it is harmless once everything is advertised)."""
    names = set(getattr(agent, "_lazy_all_tool_names", None) or set())
    if not names:
        return 0
    advertised = {(t.get("function", {}) or {}).get("name") for t in (agent.tools or [])}
    missing = names - advertised - {None}
    if not missing:
        return 0
    defs = registry.get_definitions(missing)
    added = 0
    for d in defs:
        nm = (d.get("function", {}) or {}).get("name")
        if nm and nm not in advertised:
            agent.tools.append(d)
            advertised.add(nm)
            added += 1
    agent.valid_tool_names = set(getattr(agent, "valid_tool_names", None) or set()) | advertised
    agent.valid_tool_names.discard(None)
    if getattr(agent, "_lazy_loaded_tools", None) is None:
        agent._lazy_loaded_tools = set()
    agent._lazy_loaded_tools.update(n for n in advertised if n)
    return added


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

# plan 2.5 — the fast lane's `escalate` tool lives in agent/escalation.py (it
# needs agent-loop state, not just a handler), but tool discovery only walks
# tools/*.py. Importing it here is the discovery hook; its own check_fn keeps it
# out of the tool list unless a fast lane is configured.
try:  # pragma: no cover - import wiring
    import agent.escalation  # noqa: F401
except Exception:  # pragma: no cover
    logger.debug("escalation tool not registered", exc_info=True)
