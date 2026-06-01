"""jarviscopilot-code-assist MCP server — exposes JarvisCopilot's shared code-memory
(+ general memory query) to Claude Code over stdio. Reaches hermes via the paired
pinned connection (code_memory_client)."""
from __future__ import annotations

from jc_client import code_memory_client as cmc


# ── tool implementations (plain functions, unit-testable) ──
def _register_project(name: str, root: str = "", remote: str = "") -> dict:
    try:
        slug = cmc.slug_for(root or ".", remote) if remote else cmc.current_slug(root or None)
        return cmc.register(slug, name or slug, root or ".", remote)
    except cmc.NotPaired as e:
        return {"error": str(e)}


def _store_code_knowledge(entry_type: str, content: str, project: str | None = None) -> dict:
    try:
        slug = project or cmc.current_slug()
        return cmc.store(slug, "knowledge", entry_type, content)
    except cmc.NotPaired as e:
        return {"error": str(e)}


def _recall_code_knowledge(project: str | None = None, query: str = "", limit: int = 20) -> str:
    try:
        slug = project or cmc.current_slug()
        rows = cmc.search(slug, "knowledge", q=query or "", limit=limit)
        if not rows:
            return "(no matching knowledge yet)"
        lines = [f"{r.get('id','')}  [{r.get('entry_type','')}] {r.get('first_line','')}" for r in rows]
        return ("Compact matches (id  [type]  summary). Call get_code_knowledge(ids=[...]) to read the "
                "full body of the FEW you actually need — don't fetch them all:\n" + "\n".join(lines))
    except cmc.NotPaired as e:
        return f"error: {e}"


def _get_code_knowledge(ids) -> str:
    try:
        if isinstance(ids, str):
            ids = [i.strip() for i in ids.split(",") if i.strip()]
        rows = cmc.get_by_ids(list(ids or []))
        if not rows:
            return "(no entries for those ids)"
        return "\n\n".join(
            f"[{r.get('entry_type','')}] ({r.get('ts','')})\n{r.get('content','')}" for r in rows)
    except cmc.NotPaired as e:
        return f"error: {e}"


def _store_session_handoff(content: str, project: str | None = None) -> dict:
    try:
        slug = project or cmc.current_slug()
        return cmc.store(slug, "sessions", "claude", content)
    except cmc.NotPaired as e:
        return {"error": str(e)}


def _recall_session_handoff(project: str | None = None, limit: int = 3) -> str:
    try:
        slug = project or cmc.current_slug()
        rows = cmc.recall(slug, "sessions", limit=limit)
        return "\n\n".join(f"{r.get('id','')}  [{r.get('ts','')}]\n{r.get('content','')}" for r in rows) or "(no prior sessions)"
    except cmc.NotPaired as e:
        return f"error: {e}"


def _edit_code_memory(eid: str, content: str, entry_type: str = "") -> dict:
    try:
        return cmc.update(eid, content, entry_type or "")
    except cmc.NotPaired as e:
        return {"error": str(e)}


def _delete_code_memory(eid: str) -> dict:
    try:
        return cmc.delete_by_id(eid)
    except cmc.NotPaired as e:
        return {"error": str(e)}


def _query_memory(query: str = "") -> str:
    try:
        from jc_client import credentials
        from jc_client.protocol import HttpClient
        creds = credentials.load()
        if not creds.paired:
            return "error: not paired"
        data = HttpClient(creds.server_url, cookie=creds.cookie,
                          expected_fingerprint=creds.cert_fingerprint,
                          cf_client_id=creds.cf_client_id,
                          cf_client_secret=creds.cf_client_secret
                          ).request_json("GET", "/api/memory").json()
        text = ((data.get("memory", "") or "") + "\n\n" + (data.get("user", "") or "")).strip()
        if query:
            text = "\n".join(ln for ln in text.splitlines() if query.lower() in ln.lower()) or text
        return text[:20000] or "(empty)"
    except Exception as e:
        return f"error: {e}"


def _ask(question: str) -> str:
    try:
        return cmc.ask_agent(question)
    except cmc.NotPaired as e:
        return f"error: {e}"


def _run_skill(skill: str, tool_input: str = "") -> str:
    try:
        return cmc.ask_agent(tool_input, skill=skill)
    except cmc.NotPaired as e:
        return f"error: {e}"


def build_server():
    from mcp.server.fastmcp import FastMCP
    mcp = FastMCP("jarviscopilot-code-assist")

    @mcp.tool()
    def register_project(name: str, root: str = "", remote: str = "") -> dict:
        """Register the current project with JarvisCopilot's code-memory (by git remote/dir slug)."""
        return _register_project(name, root, remote)

    @mcp.tool()
    def store_code_knowledge(entry_type: str, content: str, project: str = "") -> dict:
        """Store ONE durable coding fact for this project. entry_type: bug|fix|repo_structure|gotcha|decision|note.

        Keep it SHORT — a 1-3 sentence declarative fact (~400 chars), one fact per call.
        Store proactively when you fix a non-obvious bug, learn repo structure, hit a
        gotcha, make a decision, or find an approach works/fails. Do NOT store run-specific
        results, dated verdicts, PR/commit SHAs, or anything stale within a week — those go
        in a session handoff, not knowledge. Returns a `warning` if the entry is too long."""
        return _store_code_knowledge(entry_type, content, project or None)

    @mcp.tool()
    def recall_code_knowledge(project: str = "", query: str = "", limit: int = 20) -> str:
        """Search this project's durable coding knowledge. Returns COMPACT ranked rows
        (id + type + one-line summary), token-cheap. Pass `query` to rank by relevance.
        Then call get_code_knowledge(ids=[...]) to read the full body of only the few you
        need. Prefer this over dumping everything."""
        return _recall_code_knowledge(project or None, query, limit)

    @mcp.tool()
    def get_code_knowledge(ids: list[str]) -> str:
        """Fetch the FULL bodies of specific knowledge entries by their ids (from
        recall_code_knowledge). Fetch only the ids you actually need."""
        return _get_code_knowledge(ids)

    @mcp.tool()
    def edit_code_memory(id: str, content: str, entry_type: str = "") -> dict:
        """Edit an existing entry IN PLACE by its id (ids come from
        recall_code_knowledge / recall_session_handoff). Replaces its content — and
        entry_type if given (knowledge: bug|fix|repo_structure|gotcha|decision|note) —
        while preserving its timestamp. Prefer this over storing a near-duplicate when
        correcting or shortening a fact."""
        return _edit_code_memory(id, content, entry_type)

    @mcp.tool()
    def delete_code_memory(id: str) -> dict:
        """Delete a single code-memory entry by its id (from recall_code_knowledge /
        recall_session_handoff). Precise — removes only that entry. Use for stale,
        wrong, or duplicate entries."""
        return _delete_code_memory(id)

    @mcp.tool()
    def store_session_handoff(content: str, project: str = "") -> dict:
        """Store a session handoff (what was done, current state, open threads)."""
        return _store_session_handoff(content, project or None)

    @mcp.tool()
    def recall_session_handoff(project: str = "", limit: int = 3) -> str:
        """Recall the latest session handoff(s) for this project."""
        return _recall_session_handoff(project or None, limit)

    @mcp.tool()
    def query_memory(query: str = "") -> str:
        """Read JarvisCopilot's general memory (MEMORY.md / USER.md)."""
        return _query_memory(query)

    @mcp.tool()
    def ask(question: str) -> str:
        """Ask the JarvisCopilot agent a one-shot question (uses its model, skills, and memory). Slower than recall — use for reasoning/help, not for memory lookups."""
        return _ask(question)

    @mcp.tool()
    def run_skill(skill: str, tool_input: str = "") -> str:
        """Run a named JarvisCopilot skill on the given input via a one-shot agent turn."""
        return _run_skill(skill, tool_input)

    return mcp


def main():
    build_server().run()


if __name__ == "__main__":
    main()
