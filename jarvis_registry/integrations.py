"""An integration: a registry space plus the skills and schedules that belong to it.

The store (``jarvis_registry.store``) knows nothing about skills or cron jobs. This
module is the join: which skills declare ``integration: <space id>`` in their front
matter, which scheduled jobs belong to a space, and what a run should be told about
the space it is running for.

That last part is what makes an integration a unit of work rather than a folder. When
a schedule fires — or a chat turn works inside an integration — the turn is handed the
space's catalog (what it stores, in one line each) and its skills, instead of being
left to discover them.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

GENERAL_ID = "general"
# The one-time workspace migration's own bookkeeping. It is not data the
# integration keeps, so neither a run nor the page is told about it.
BOOKKEEPING_KEYS = {"imported_files"}
GENERAL_NAME = "General"
GENERAL_DESCRIPTION = "Schedules and notes that don't belong to a larger integration."


def ensure_general() -> str:
    """The catch-all integration, so no schedule is homeless."""
    from jarvis_registry.store import shared

    shared().space(GENERAL_ID, name=GENERAL_NAME, description=GENERAL_DESCRIPTION, icon="dots")
    return GENERAL_ID


def skills_for(space_id: str) -> list[dict]:
    """Skills whose front matter names this integration.

    Returns ``[{"name", "description", "path"}]``, sorted by name. A skill directory
    that can't be read is skipped rather than failing the caller — a broken skill
    should not stop an integration from running.
    """
    if not space_id:
        return []
    out: list[dict] = []
    for skill_md in _skill_files():
        try:
            text = skill_md.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "integration:" not in text:      # cheap reject before parsing YAML
            continue
        meta = _front_matter(text)
        if str(meta.get("integration") or "").strip().lower() != space_id:
            continue
        out.append({
            "name": str(meta.get("name") or skill_md.parent.name),
            "description": str(meta.get("description") or "").strip(),
            "path": str(skill_md),
        })
    return sorted(out, key=lambda s: s["name"])


def schedules_for(space_id: str) -> list[dict]:
    """Cron jobs that belong to this integration (``general`` also takes untagged ones)."""
    from cron.jobs import list_jobs

    out = []
    for job in list_jobs(include_disabled=True):
        owner = (job.get("integration") or "").strip().lower() or GENERAL_ID
        if owner == space_id:
            out.append(job)
    return sorted(out, key=lambda j: str(j.get("name") or ""))


def summary(space_id: str) -> dict:
    """Everything the Integrations page shows for one integration."""
    from jarvis_registry.store import shared

    space = shared().open(space_id)
    schedules = schedules_for(space_id)
    return {
        **space.info(),
        "collections": space.collections(),
        "documents": [d for d in space.documents() if d["key"] not in BOOKKEEPING_KEYS],
        "skills": skills_for(space_id),
        "schedules": [_schedule_row(job) for job in schedules],
        "schedule_count": len(schedules),
    }


def _schedule_row(job: dict) -> dict:
    """What the page shows for a schedule.

    Not the whole job: a prompt can run to thousands of words, and the page only
    needs the line it draws. Run/pause/edit still go through /api/crons/*, which
    serves the full record.
    """
    return {
        "id": job.get("id"),
        "name": job.get("name") or job.get("id"),
        "schedule": job.get("schedule"),
        "enabled": job.get("enabled", True),
        "state": job.get("state"),
        "last_run": job.get("last_run"),
        "next_run": job.get("next_run"),
    }


def overview() -> list[dict]:
    """Every integration, in the order the list page shows them."""
    from jarvis_registry.store import shared

    out = []
    reg = shared()
    for row in reg.spaces():
        schedules = schedules_for(row["id"])
        enabled = [s for s in schedules if s.get("enabled", True)]
        runs = [s.get("last_run") for s in schedules if s.get("last_run")]
        space = reg.open(row["id"])
        collections = space.collections()
        out.append({
            **row,
            "schedule_count": len(schedules),
            "enabled_schedule_count": len(enabled),
            "skill_count": len(skills_for(row["id"])),
            "collection_count": len(collections),
            "document_count": len(space.documents()),
            "record_count": sum(int(c.get("count") or 0) for c in collections),
            "last_run": max(runs) if runs else None,
        })
    return out


def context_block(space_id: str, max_items: int = 20) -> str:
    """What a run is told about the integration it is running for.

    A compact block: the space id to pass to the registry tools, what it holds, and
    which skills belong to it. Empty string when the space is unknown, so a caller can
    prepend it unconditionally.
    """
    from jarvis_registry.store import shared

    try:
        space = shared().open(space_id)
        info = space.info()
    except Exception:
        return ""

    lines = [
        f"[Integration: {info['name']} (space id \"{info['id']}\").",
        str(info.get("description") or ""),
        "Its long-lived data is in the central registry — read and write it with the "
        "registry_* tools using that space id, not files in the workspace.",
    ]
    collections = space.collections()[:max_items]
    if collections:
        lines.append("Collections (append with registry_append, read with registry_query):")
        for c in collections:
            described = f" — {c['description']}" if c.get("description") else ""
            lines.append(f"  - {c['name']} ({c['count']} records){described}")
    documents = [d for d in space.documents() if d["key"] not in BOOKKEEPING_KEYS][:max_items]
    if documents:
        lines.append("Documents (registry_get / registry_put):")
        for d in documents:
            described = f" — {d['description']}" if d.get("description") else ""
            lines.append(f"  - {d['key']}{described}")
    skills = skills_for(space_id)
    if skills:
        lines.append("Skills that belong to this integration: "
                     + ", ".join(s["name"] for s in skills) + ".")
    lines.append("]")
    return "\n".join(line for line in lines if line)


def owner_of_skill(skill_name: str) -> Optional[str]:
    """The integration a skill belongs to, or None."""
    for skill_md in _skill_files():
        try:
            text = skill_md.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        meta = _front_matter(text)
        if str(meta.get("name") or skill_md.parent.name) == skill_name:
            owner = str(meta.get("integration") or "").strip().lower()
            return owner or None
    return None


# ── internals ────────────────────────────────────────────────────────────────
def _skill_files() -> list[Path]:
    try:
        from tools.skills_tool import SKILLS_DIR
    except Exception:
        return []
    root = Path(SKILLS_DIR)
    if not root.exists():
        return []
    try:
        return sorted(root.glob("*/*/SKILL.md")) + sorted(root.glob("*/SKILL.md"))
    except OSError:
        return []


def _front_matter(text: str) -> dict[str, Any]:
    try:
        from agent.skill_utils import parse_frontmatter

        meta, _body = parse_frontmatter(text)
        return meta or {}
    except Exception:
        logger.debug("could not parse skill front matter", exc_info=True)
        return {}
