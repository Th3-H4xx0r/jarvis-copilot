"""jarviscopilot-code-assist MCP server — exposes JarvisCopilot's shared code-memory
(+ general memory query) to Claude Code over stdio. Reaches hermes via the paired
pinned connection (code_memory_client). The tools themselves are defined once, in
code_assist_mcp, which the server host shares."""
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
        data = HttpClient.from_creds(creds).request_json("GET", "/api/memory").json()
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


# The tool definitions live in code_assist_mcp (shared with the server host);
# this host's implementations reach hermes over the paired connection.
DESKTOP_BACKEND = {
    "register_project": _register_project,
    "store_code_knowledge": _store_code_knowledge,
    "recall_code_knowledge": _recall_code_knowledge,
    "get_code_knowledge": _get_code_knowledge,
    "edit_code_memory": _edit_code_memory,
    "delete_code_memory": _delete_code_memory,
    "store_session_handoff": _store_session_handoff,
    "recall_session_handoff": _recall_session_handoff,
    "query_memory": _query_memory,
    "ask": _ask,
    "run_skill": _run_skill,
}


def build_server():
    from jc_client.code_assist_mcp import build_server as build
    return build(DESKTOP_BACKEND)


def main():
    build_server().run()


if __name__ == "__main__":
    main()
