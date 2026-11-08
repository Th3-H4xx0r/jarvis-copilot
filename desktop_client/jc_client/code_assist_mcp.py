"""The ``jarviscopilot-code-assist`` MCP tools: names, arguments and the
descriptions Claude reads. The one definition, for both hosts.

Each host supplies the implementations as a ``backend`` dict of tool name ->
callable:

* the desktop (``jc_client/mcp_server.py``) reaches hermes over the paired,
  pinned connection;
* the server (``agent/coding_mcp_server.py``, which loads THIS file by path —
  the server has no ``jc_client`` install) talks to its local code-memory store.

A tool is offered only when the backend implements it (the server has no
``ask`` / ``run_skill``). Keep this file free of jc_client imports so the server
can load it.
"""
from __future__ import annotations

# Every tool a backend may implement; the first group is required.
REQUIRED_TOOLS = (
    "register_project", "store_code_knowledge", "recall_code_knowledge",
    "get_code_knowledge", "edit_code_memory", "delete_code_memory",
    "store_session_handoff", "recall_session_handoff", "query_memory",
)
OPTIONAL_TOOLS = ("ask", "run_skill")


def build_server(backend: dict):
    missing = [name for name in REQUIRED_TOOLS if name not in backend]
    if missing:
        raise ValueError(f"code-assist backend lacks {missing}")
    from mcp.server.fastmcp import FastMCP
    mcp = FastMCP("jarviscopilot-code-assist")
    b = backend

    @mcp.tool()
    def register_project(name: str, root: str = "", remote: str = "") -> dict:
        """Register the current project with JarvisCopilot's code-memory (by git remote/dir slug)."""
        return b["register_project"](name, root, remote)

    @mcp.tool()
    def store_code_knowledge(entry_type: str, content: str, project: str = "") -> dict:
        """Store ONE durable coding fact for this project. entry_type: bug|fix|repo_structure|gotcha|decision|note.

        Keep it SHORT — a 1-3 sentence declarative fact (~400 chars), one fact per call.
        Store proactively when you fix a non-obvious bug, learn repo structure, hit a
        gotcha, make a decision, or find an approach works/fails. Do NOT store run-specific
        results, dated verdicts, PR/commit SHAs, or anything stale within a week — those go
        in a session handoff, not knowledge. Returns a `warning` if the entry is too long."""
        return b["store_code_knowledge"](entry_type, content, project)

    @mcp.tool()
    def recall_code_knowledge(project: str = "", query: str = "", limit: int = 20) -> str:
        """Search this project's durable coding knowledge. Returns COMPACT ranked rows
        (id + type + one-line summary), token-cheap. Pass `query` to rank by relevance.
        Then call get_code_knowledge(ids=[...]) to read the full body of only the few you
        need. Prefer this over dumping everything."""
        return b["recall_code_knowledge"](project, query, limit)

    @mcp.tool()
    def get_code_knowledge(ids: list[str]) -> str:
        """Fetch the FULL bodies of specific knowledge entries by their ids (from
        recall_code_knowledge). Fetch only the ids you actually need."""
        return b["get_code_knowledge"](ids)

    @mcp.tool()
    def edit_code_memory(id: str, content: str, entry_type: str = "") -> dict:
        """Edit an existing entry IN PLACE by its id (ids come from
        recall_code_knowledge / recall_session_handoff). Replaces its content — and
        entry_type if given (knowledge: bug|fix|repo_structure|gotcha|decision|note) —
        while preserving its timestamp. Prefer this over storing a near-duplicate when
        correcting or shortening a fact."""
        return b["edit_code_memory"](id, content, entry_type)

    @mcp.tool()
    def delete_code_memory(id: str) -> dict:
        """Delete a single code-memory entry by its id (from recall_code_knowledge /
        recall_session_handoff). Precise — removes only that entry. Use for stale,
        wrong, or duplicate entries."""
        return b["delete_code_memory"](id)

    @mcp.tool()
    def store_session_handoff(content: str, project: str = "") -> dict:
        """Store a session handoff (what was done, current state, open threads)."""
        return b["store_session_handoff"](content, project)

    @mcp.tool()
    def recall_session_handoff(project: str = "", limit: int = 3) -> str:
        """Recall the latest session handoff(s) for this project."""
        return b["recall_session_handoff"](project, limit)

    @mcp.tool()
    def query_memory(query: str = "") -> str:
        """Read JarvisCopilot's general memory (MEMORY.md / USER.md)."""
        return b["query_memory"](query)

    if "ask" in b:
        @mcp.tool()
        def ask(question: str) -> str:
            """Ask the JarvisCopilot agent a one-shot question (uses its model, skills, and memory). Slower than recall — use for reasoning/help, not for memory lookups."""
            return b["ask"](question)

    if "run_skill" in b:
        @mcp.tool()
        def run_skill(skill: str, tool_input: str = "") -> str:
            """Run a named JarvisCopilot skill on the given input via a one-shot agent turn."""
            return b["run_skill"](skill, tool_input)

    return mcp
