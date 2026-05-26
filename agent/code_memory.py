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
# Soft target for a knowledge entry: a short, declarative fact (1-3 sentences).
# Above this we still save (never lose data) but return a warning nudging the
# writer to trim to the durable nugget. See SKILLs / store_code_knowledge.
SOFT_ENTRY_CHARS = 600
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
    slug = _sanitize(slug) or "project"  # keep dir, projects.json key, and index slug consistent
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
    res = {"ts": ts, "entry_type": entry_type}
    if kind == "knowledge" and len(content) > SOFT_ENTRY_CHARS:
        res["warning"] = (
            f"Stored, but this entry is {len(content)} chars. Code-memory knowledge "
            "should be a short declarative fact (1-3 sentences, ~400 chars). Trim to the "
            "durable nugget or split it; keep run-specific results/numbers in a session "
            "handoff, not knowledge."
        )
    return res


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
    """Global counts. Uses the SQLite index when available; the project count is
    taken from list_all_projects so it matches the browsable list."""
    projects = len(list_all_projects(home))
    try:
        from agent import code_memory_index as _idx
        s = _idx.stats(home=home)
        return {"projects": projects, "knowledge": s["knowledge"], "sessions": s["sessions"],
                "by_type": s["by_type"], "last_activity": s["last_activity"]}
    except Exception:
        return _stats_scan(home)


def _stats_scan(home: Any = None) -> dict:
    """Markdown-scan fallback for stats() when the index is unavailable."""
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


# =============================================================================
# Progressive recall (token-cheap): search -> pick ids -> fetch bodies.
# All index-backed with a markdown-scan fallback so recall never breaks.
# =============================================================================
def _compact_rows(slug: str, kind: str, rows_newest_first: list[dict]) -> list[dict]:
    """Build compact rows with ids matching the index's scheme.

    The index assigns the ``::ordinal`` in FILE order (oldest-first), so compute
    ordinals on the reversed list, then return rows still newest-first to match
    read_entries / the index's recency ordering.
    """
    safe = _sanitize(slug)
    ordinal_by_pos: dict[int, int] = {}
    seen: dict[str, int] = {}
    for r in reversed(rows_newest_first):  # oldest-first = file order
        o = seen.get(r["ts"], 0)
        seen[r["ts"]] = o + 1
        ordinal_by_pos[id(r)] = o
    out = []
    for r in rows_newest_first:
        body = (r.get("content") or "").strip()
        out.append({"id": f"{safe}::{kind}::{r['ts']}::{ordinal_by_pos[id(r)]}",
                    "slug": safe, "kind": kind, "entry_type": r["entry_type"],
                    "ts": r["ts"], "first_line": body.splitlines()[0][:120] if body else ""})
    return out


def search(slug: str, kind: str = "knowledge", entry_type: str | None = None,
           query: str | None = None, limit: int = 20, offset: int = 0,
           home: Any = None) -> list[dict]:
    """Compact ranked rows (no bodies). Index-backed; markdown fallback."""
    try:
        from agent import code_memory_index as _idx
        return _idx.search(slug=slug, kind=kind, entry_type=entry_type,
                           query=query, limit=limit, offset=offset, home=home)
    except Exception:
        rows = read_entries(slug, kind, limit=10 ** 9, home=home)
        pairs = list(zip(_compact_rows(slug, kind, rows), rows))  # ids over the FULL set
        if entry_type:
            pairs = [(c, r) for c, r in pairs if r["entry_type"] == entry_type]
        if query:
            ql = query.lower()
            pairs = [(c, r) for c, r in pairs if ql in (r.get("content") or "").lower()]
        return [c for c, _ in pairs[offset:offset + max(1, limit)]]


def get_by_ids(ids: list[str], home: Any = None) -> list[dict]:
    """Full bodies for the given entry ids (id = slug::kind::ts::ordinal)."""
    try:
        from agent import code_memory_index as _idx
        return _idx.get_by_ids(ids, home=home)
    except Exception:
        out = []
        for eid in ids or []:
            parts = (eid or "").split("::")
            if len(parts) < 3:
                continue
            slug, kind, ts = parts[0], parts[1], parts[2]
            if kind not in KINDS:
                continue
            try:
                ordn = int(parts[3]) if len(parts) >= 4 else 0
            except ValueError:
                ordn = 0
            # ordinal is file-order (oldest-first); read_entries is newest-first
            file_order = list(reversed(read_entries(slug, kind, limit=10 ** 9, home=home)))
            same_ts = [r for r in file_order if r["ts"] == ts]
            if 0 <= ordn < len(same_ts):
                r = same_ts[ordn]
                out.append({"id": eid, "slug": _sanitize(slug), "kind": kind,
                            "entry_type": r["entry_type"], "ts": ts, "content": r["content"]})
        return out


def project_counts(home: Any = None) -> dict:
    """{slug: {'knowledge': n, 'sessions': m}}. Index-backed; markdown fallback."""
    try:
        from agent import code_memory_index as _idx
        return _idx.project_counts(home=home)
    except Exception:
        out = {}
        for slug in list_all_projects(home):
            out[_sanitize(slug)] = {"knowledge": count_entries(slug, "knowledge", home=home),
                                    "sessions": count_entries(slug, "sessions", home=home)}
        return out


_DIGEST_NOTABLE = ("decision", "gotcha", "fix", "bug")


def digest(slug: str, home: Any = None) -> str:
    """A tiny (<300-token) session-start digest: counts + most-recent handoff +
    a few notable knowledge first-lines. Full entries stay recallable on demand."""
    try:
        from agent import code_memory_index as _idx
        c = _idx.counts(slug, home=home)
        nk, ns = c.get("knowledge", 0), c.get("sessions", 0)
        sess = _idx.search(slug=slug, kind="sessions", limit=2, home=home)
        know = _idx.search(slug=slug, kind="knowledge", limit=14, home=home)
    except Exception:
        nk = count_entries(slug, "knowledge", home=home)
        ns = count_entries(slug, "sessions", home=home)
        sess = _compact_rows(slug, "sessions", read_entries(slug, "sessions", limit=2, home=home))
        know = _compact_rows(slug, "knowledge", read_entries(slug, "knowledge", limit=14, home=home))
    lines = [f"{nk} knowledge · {ns} handoffs"]
    if sess:
        lines.append(f"Latest handoff: {sess[0]['first_line']}")
    notable = [r for r in know if r["entry_type"] in _DIGEST_NOTABLE][:5]
    if notable:
        lines.append("Key knowledge:")
        lines += [f"- [{r['entry_type']}] {r['first_line']}" for r in notable]
    lines.append("(Recall full entries on demand: search/get_code_knowledge — don't ask for everything.)")
    return "\n".join(lines)
