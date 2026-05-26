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
import shutil
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
    block = f"\n{_SEP}## {ts} \xb7 {entry_type}\n{content.rstrip()}\n"
    with open(f, "a", encoding="utf-8") as fh:
        fh.write(block)
    return {"ts": ts, "entry_type": entry_type}


# Each entry header is prefixed with a record-separator control char (U+001E)
# that free-text bodies never contain, so an entry whose BODY quotes a line
# like `## 2026-… · bug` can't be mis-parsed as a second entry (which would
# make delete_entry truncate the real entry — data loss). New writes use the
# sentinel; files written before it (no \x1e) fall back to the legacy header
# regex so existing data still reads.
_TS_RE = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"
_SEP = "\x1e"
_ENTRY_RE = re.compile(
    rf"^{_SEP}## (?P<ts>{_TS_RE}) \xb7 (?P<type>[^\n]+)\n(?P<body>.*?)(?=\n{_SEP}## |\Z)",
    re.DOTALL | re.MULTILINE,
)
_LEGACY_ENTRY_RE = re.compile(
    rf"^## (?P<ts>{_TS_RE}) \xb7 (?P<type>[^\n]+)\n(?P<body>.*?)(?=\n## {_TS_RE} \xb7 |\Z)",
    re.DOTALL | re.MULTILINE,
)


def _entries_re(text: str):
    """Sentinel parser for new files; legacy parser for pre-sentinel files."""
    return _ENTRY_RE if _SEP in text else _LEGACY_ENTRY_RE


def read_entries(slug, kind, limit: int = _DEFAULT_LIMIT, home: Any = None) -> list[dict]:
    f = _file(slug, kind, home)
    if not f.exists():
        return []
    text = f.read_text(encoding="utf-8", errors="replace")
    rows = [
        {"ts": m.group("ts"), "entry_type": m.group("type").strip(), "content": m.group("body").strip()}
        for m in _entries_re(text).finditer(text)
    ]
    rows.reverse()  # newest first
    if not isinstance(limit, int) or limit <= 0:
        limit = _DEFAULT_LIMIT
    return rows[:limit]


def count_entries(slug, kind, home: Any = None) -> int:
    return len(read_entries(slug, kind, limit=10 ** 9, home=home))


def delete_entry(slug, kind, ts, home: Any = None) -> int:
    """Remove every entry whose timestamp == ts. Returns the count removed."""
    f = _file(slug, kind, home)  # validates kind + slug
    if not f.exists():
        return 0
    text = f.read_text(encoding="utf-8", errors="replace")
    kept, removed = [], 0
    for m in _entries_re(text).finditer(text):
        if m.group("ts") == ts:
            removed += 1
            continue
        kept.append((m.group("ts"), m.group("type").strip(), m.group("body").strip()))
    if removed:
        # Rewrite in the sentinel format regardless of the source (migrates a
        # legacy file on first edit so future parses are collision-proof).
        out = "".join(f"\n{_SEP}## {t} \xb7 {ty}\n{b}\n" for (t, ty, b) in kept)
        f.write_text(out, encoding="utf-8")
    return removed


def delete_project(slug, home: Any = None) -> bool:
    """Remove the project's directory + its projects.json entry. True if it existed."""
    safe = _sanitize(slug)
    if not safe:
        return False
    existed = False
    d = _root(home) / safe
    if d.exists():
        shutil.rmtree(d, ignore_errors=True)
        existed = True
    idx = list_projects(home)
    if safe in idx:
        del idx[safe]
        (_root(home) / "projects.json").write_text(json.dumps(idx, indent=2), encoding="utf-8")
        existed = True
    return existed


def _fs_slugs(home: Any = None) -> set:
    """Slugs of code_memory subdirs that actually have entry files on disk."""
    root = _root(home)
    out: set = set()
    if root.is_dir():
        for d in root.iterdir():
            if d.is_dir() and any(d.glob("*.md")):
                out.add(d.name)
    return out


def list_all_projects(home: Any = None) -> dict:
    """Registered projects PLUS stub entries for dirs that have entries but no
    index row, so the browsable list matches what stats() counts."""
    idx = dict(list_projects(home))
    for slug in _fs_slugs(home):
        idx.setdefault(slug, {"name": slug, "root": "", "remote": "",
                              "first_seen": "", "last_seen": ""})
    return idx


def stats(home: Any = None) -> dict:
    """Global counts across all projects (registered + unregistered dirs)."""
    idx = list_projects(home)
    slugs: set = set(idx.keys()) | _fs_slugs(home)
    total_k = total_s = 0
    by_type: dict = {}
    last = None
    for slug in slugs:
        for row in read_entries(slug, "knowledge", limit=10 ** 9, home=home):
            total_k += 1
            by_type[row["entry_type"]] = by_type.get(row["entry_type"], 0) + 1
            if last is None or row["ts"] > last:
                last = row["ts"]
        for row in read_entries(slug, "sessions", limit=10 ** 9, home=home):
            total_s += 1
            if last is None or row["ts"] > last:
                last = row["ts"]
    return {"projects": len(slugs), "knowledge": total_k, "sessions": total_s,
            "by_type": by_type, "last_activity": last}
