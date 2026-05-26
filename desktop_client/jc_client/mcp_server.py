"""jarvisclaw-code-assist MCP server — exposes JarvisCopilot's shared code-memory
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


def _recall_code_knowledge(project: str | None = None, limit: int = 50) -> str:
    try:
        slug = project or cmc.current_slug()
        rows = cmc.recall(slug, "knowledge", limit=limit)
        return "\n\n".join(f"[{r.get('entry_type','')}] {r.get('content','')}" for r in rows) or "(no knowledge yet)"
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
        return "\n\n".join(f"[{r.get('ts','')}] {r.get('content','')}" for r in rows) or "(no prior sessions)"
    except cmc.NotPaired as e:
        return f"error: {e}"


def _query_memory(query: str = "") -> str:
    try:
        from jc_client import credentials
        from jc_client.protocol import HttpClient
        creds = credentials.load()
        if not creds.paired:
            return "error: not paired"
        data = HttpClient(creds.server_url, cookie=creds.cookie,
                          expected_fingerprint=creds.cert_fingerprint
                          ).request_json("GET", "/api/memory").json()
        text = ((data.get("memory", "") or "") + "\n\n" + (data.get("user", "") or "")).strip()
        if query:
            text = "\n".join(ln for ln in text.splitlines() if query.lower() in ln.lower()) or text
        return text[:20000] or "(empty)"
    except Exception as e:
        return f"error: {e}"


def build_server():
    from mcp.server.fastmcp import FastMCP
    mcp = FastMCP("jarvisclaw-code-assist")

    @mcp.tool()
    def register_project(name: str, root: str = "", remote: str = "") -> dict:
        """Register the current project with JarvisCopilot's code-memory (by git remote/dir slug)."""
        return _register_project(name, root, remote)

    @mcp.tool()
    def store_code_knowledge(entry_type: str, content: str, project: str = "") -> dict:
        """Store a durable coding learning. entry_type: bug|fix|repo_structure|gotcha|decision|note."""
        return _store_code_knowledge(entry_type, content, project or None)

    @mcp.tool()
    def recall_code_knowledge(project: str = "", limit: int = 50) -> str:
        """Recall durable coding knowledge for this project (newest first)."""
        return _recall_code_knowledge(project or None, limit)

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

    return mcp


def main():
    build_server().run()


if __name__ == "__main__":
    main()
