"""Client-side wrapper over the webui /api/code-memory endpoints, using the
paired pinned connection. Shared by the MCP server and the `code-memory` CLI."""
from __future__ import annotations

import os
import re
import subprocess
from urllib.parse import quote

from jc_client import credentials
from jc_client.protocol import HttpClient


class NotPaired(RuntimeError):
    pass


def _slugify(seg: str) -> str:
    s = seg.strip().lower().replace(" ", "-")
    return re.sub(r"[^a-z0-9._-]+", "_", s).strip("_.")


def slug_for(root: str, remote: str | None) -> str:
    if remote:
        r = re.sub(r"^[a-z]+://", "", remote.strip(), flags=re.I)
        r = re.sub(r"^[^@/]+@", "", r).replace(":", "/")
        r = re.sub(r"\.git$", "", r, flags=re.I)
        slug = _slugify("_".join(p for p in r.split("/") if p))
        if slug:
            return slug
    return _slugify(os.path.basename(os.path.normpath(root))) or "project"


def current_slug(root: str | None = None) -> str:
    root = root or os.getcwd()
    try:
        remote = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                                capture_output=True, text=True, timeout=5).stdout.strip() or None
    except Exception:
        remote = None
    return slug_for(root, remote)


def _http() -> HttpClient:
    creds = credentials.load()
    if not creds.paired:
        raise NotPaired("not paired — run `jc-client pair`")
    return HttpClient(creds.server_url, cookie=creds.cookie, expected_fingerprint=creds.cert_fingerprint)


def register(slug, name, root, remote=""):
    return _http().request_json("POST", "/api/code-memory/register",
                                {"slug": slug, "name": name, "root": root, "remote": remote}).json()


def store(slug, kind, entry_type, content):
    return _http().request_json("POST", "/api/code-memory/write",
                                {"slug": slug, "kind": kind, "entry_type": entry_type, "content": content}).json()


def recall(slug, kind, limit=50):
    path = f"/api/code-memory?project={quote(slug)}&kind={quote(kind)}&limit={int(limit)}"
    return _http().request_json("GET", path).json().get("entries", [])


def search(slug, kind="knowledge", q="", entry_type="", limit=20, offset=0):
    """Compact ranked rows (id/entry_type/ts/first_line) — no bodies."""
    path = (f"/api/code-memory/search?project={quote(slug)}&kind={quote(kind)}"
            f"&limit={int(limit)}&offset={int(offset)}")
    if q:
        path += f"&q={quote(q)}"
    if entry_type:
        path += f"&type={quote(entry_type)}"
    return _http().request_json("GET", path).json().get("entries", [])


def get_by_ids(ids):
    """Full bodies for the given entry ids."""
    if not ids:
        return []
    path = f"/api/code-memory/entries?ids={quote(','.join(ids))}"
    return _http().request_json("GET", path).json().get("entries", [])


def digest(slug):
    """Small (<300-token) session-start digest string for a project."""
    path = f"/api/code-memory/digest?project={quote(slug)}"
    return _http().request_json("GET", path).json().get("digest", "")


def delete_entry(slug, kind, ts):
    return _http().request_json("POST", "/api/code-memory/delete-entry",
                                {"slug": slug, "kind": kind, "ts": ts}).json()


def delete_by_id(eid):
    """Precise single-entry delete by id (slug::kind::ts::ordinal)."""
    return _http().request_json("POST", "/api/code-memory/delete-entry", {"id": eid}).json()


def update(eid, content, entry_type=""):
    """Edit one entry in place by id; optionally change its entry_type."""
    body = {"id": eid, "content": content}
    if entry_type:
        body["entry_type"] = entry_type
    return _http().request_json("POST", "/api/code-memory/update", body).json()


def projects():
    return _http().request_json("GET", "/api/code-memory/projects").json().get("projects", {})


def ask_agent(question: str, skill: str | None = None, timeout: float = 180.0) -> str:
    """One-shot question to the JarvisCopilot agent (uses its model + skills +
    memory). Runs an ephemeral side-session via /api/btw and returns the answer.
    If `skill` is given, the prompt directs the agent to use that skill."""
    msg = question if not skill else f"Use the {skill} skill. Input:\n{question}"
    http = _http()  # raises NotPaired if unpaired
    session_id = ((http.request_json("POST", "/api/session/new", {}).json().get("session") or {})
                  .get("session_id"))
    if not session_id:
        return "error: could not create a session"
    stream_id = http.request_json(
        "POST", "/api/btw", {"session_id": session_id, "question": msg}
    ).json().get("stream_id")
    if not stream_id:
        return "error: agent did not start"
    data = http.get_sse_event(
        f"/api/chat/stream?stream_id={quote(stream_id)}", "done", timeout=timeout)
    if not data:
        return "error: no response from the agent (timed out)"
    return str(data.get("answer", "")).strip() or "(empty answer)"
