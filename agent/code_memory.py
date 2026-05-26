"""Shared, project-scoped coding memory for JarvisCopilot.

Single source of truth for the code-memory store used by BOTH the webui
endpoints (Claude, via the MCP server) and the agent's native `code_memory`
tool (JarvisCopilot's own TUI/chat). Layout under HERMES_HOME:

    code_memory/projects.json                  # {slug: {name, root, remote, ...}}
    code_memory/<slug>/knowledge.md            # durable learnings
    code_memory/<slug>/sessions.md             # session-handoff log

Same repo => same slug (normalized git remote) => same memory on any surface.
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

KINDS = ("knowledge", "sessions")
KNOWLEDGE_TYPES = ("bug", "fix", "repo_structure", "gotcha", "decision", "note")
SESSION_SURFACES = ("claude", "jarviscopilot")
MAX_ENTRY_BYTES = 64 * 1024
_DEFAULT_LIMIT = 50


def _home(home: Any = None) -> Path:
    if home is not None:
        return Path(home)
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home()


def _root(home: Any = None) -> Path:
    return _home(home) / "code_memory"


def _sanitize(seg: str) -> str:
    seg = seg.strip().lower()
    # convert spaces to hyphens for readability
    seg = seg.replace(" ", "-")
    seg = re.sub(r"[^a-z0-9._-]+", "_", seg).strip("_.")
    return seg


def slugify_remote(remote: str) -> str:
    r = remote.strip()
    r = re.sub(r"^[a-z]+://", "", r, flags=re.I)      # strip scheme
    r = re.sub(r"^[^@/]+@", "", r)                     # strip user@
    r = r.replace(":", "/")                            # scp-style host:path -> host/path
    r = re.sub(r"\.git$", "", r, flags=re.I)
    parts = [p for p in r.split("/") if p]
    return _sanitize("_".join(parts))


def project_slug(root: str, remote: str | None) -> str:
    if remote and slugify_remote(remote):
        return slugify_remote(remote)
    return _sanitize(Path(root).name) or "project"


def register_project(slug, name, root, remote, home: Any = None) -> dict:
    root_dir = _root(home)
    root_dir.mkdir(parents=True, exist_ok=True)
    (root_dir / slug).mkdir(parents=True, exist_ok=True)
    idx = list_projects(home)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    entry = idx.get(slug, {"first_seen": now})
    entry.update({"name": name, "root": root, "remote": remote or "", "last_seen": now})
    idx[slug] = entry
    (root_dir / "projects.json").write_text(json.dumps(idx, indent=2), encoding="utf-8")
    return entry


def list_projects(home: Any = None) -> dict:
    p = _root(home) / "projects.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _file(slug: str, kind: str, home: Any = None) -> Path:
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {KINDS}")
    safe = _sanitize(slug)
    if not safe:
        raise ValueError("invalid slug")
    return _root(home) / safe / f"{kind}.md"


def write_entry(slug, kind, entry_type, content, home: Any = None) -> dict:
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {KINDS}")
    if kind == "knowledge" and entry_type not in KNOWLEDGE_TYPES:
        raise ValueError(f"entry_type must be one of {KNOWLEDGE_TYPES}")
    if kind == "sessions" and entry_type not in SESSION_SURFACES:
        raise ValueError(f"surface must be one of {SESSION_SURFACES}")
    if len(content.encode("utf-8")) > MAX_ENTRY_BYTES:
        raise ValueError(f"content exceeds {MAX_ENTRY_BYTES} bytes")
    f = _file(slug, kind, home)
    f.parent.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    block = f"\n## {ts} \xb7 {entry_type}\n{content.rstrip()}\n"
    with open(f, "a", encoding="utf-8") as fh:
        fh.write(block)
    return {"ts": ts, "entry_type": entry_type}


# Header is `## <ISO-ts> · <type>`. Both the match and the entry-boundary
# lookahead require a full ISO timestamp, so a body line that merely starts
# with `## ` (or `## foo · bar`) is NOT mistaken for a new entry.
_TS_RE = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"
_ENTRY_RE = re.compile(
    rf"^## (?P<ts>{_TS_RE}) \xb7 (?P<type>[^\n]+)\n(?P<body>.*?)(?=\n## {_TS_RE} \xb7 |\Z)",
    re.DOTALL | re.MULTILINE,
)


def read_entries(slug, kind, limit: int = _DEFAULT_LIMIT, home: Any = None) -> list[dict]:
    f = _file(slug, kind, home)
    if not f.exists():
        return []
    text = f.read_text(encoding="utf-8", errors="replace")
    rows = [
        {"ts": m.group("ts"), "entry_type": m.group("type").strip(), "content": m.group("body").strip()}
        for m in _ENTRY_RE.finditer(text)
    ]
    rows.reverse()  # newest first
    if not isinstance(limit, int) or limit <= 0:
        limit = _DEFAULT_LIMIT
    return rows[:limit]
