"""Staging for cross-session writes that you want to see before they land.

``agent/background_review.py`` forks the agent after a turn and asks "should
any skill or memory be saved?", and -- in its own words -- "writes go straight
to the memory + skill stores". Over months that is how a memory file fills with
things you never agreed to and cannot easily find again. There was no review
surface: no list of what was proposed, no way to correct one entry, no way to
say no.

With ``memory.write_approval`` on, a write is not committed. It is staged as
one JSON file under ``$HERMES_HOME/pending/<kind>/`` and applied only when you
say so. Default is off, so nothing changes until you ask for it.

The staged record is deliberately the tool call, not a rendered diff: applying
it later replays the same operation through the same store, so an approved
write lands exactly the way an unreviewed one did.
"""

from __future__ import annotations

import json
import logging
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

from jarviscopilot_constants import get_hermes_home

logger = logging.getLogger(__name__)

KINDS = ("memory", "skills")


def pending_dir(kind: str) -> Path:
    """Directory holding staged writes of ``kind``."""
    if kind not in KINDS:
        raise ValueError(f"Unknown pending kind {kind!r}; expected one of {KINDS}.")
    return get_hermes_home() / "pending" / kind


def write_approval_enabled(kind: str) -> bool:
    """Whether ``kind`` writes are staged rather than committed.

    Off by default: turning this on changes where the agent's own writes go,
    and that should be a decision rather than a surprise.
    """
    section = {"memory": "memory", "skills": "skills"}[kind]
    try:
        from jarviscopilot_cli.config import load_config

        cfg = (load_config() or {}).get(section, {}) or {}
        return bool(cfg.get("write_approval", False))
    except Exception as exc:
        # Fail OPEN: a config we cannot read must not silently start swallowing
        # the agent's memory writes into a directory nobody is watching.
        logger.warning("Could not read %s.write_approval, treating as off: %s",
                       section, exc)
        return False


def _new_id(kind: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"{kind[0]}-{stamp}-{secrets.token_hex(2)}"


def stage(kind: str, *, action: str, target: str = "memory",
          content: Optional[str] = None, old_text: Optional[str] = None,
          origin: str = "unknown") -> dict:
    """Record a write for review. Returns the staged record."""
    record = {
        "id": _new_id(kind),
        "kind": kind,
        "action": action,
        "target": target,
        "content": content,
        "old_text": old_text,
        "origin": origin,
        "staged_at": datetime.now(timezone.utc).isoformat(),
    }
    directory = pending_dir(kind)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{record['id']}.json"
    path.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
    logger.info("Staged %s write %s for review (%s)", kind, record["id"], origin)
    return record


def list_pending(kind: Optional[str] = None) -> List[dict]:
    """Every staged write, oldest first. Unreadable files are skipped."""
    kinds = KINDS if kind is None else (kind,)
    out: List[dict] = []
    for k in kinds:
        directory = pending_dir(k)
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.json")):
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                logger.warning("Skipping unreadable pending write %s", path)
                continue
            if isinstance(record, dict):
                record.setdefault("id", path.stem)
                record.setdefault("kind", k)
                out.append(record)
    out.sort(key=lambda r: r.get("staged_at") or "")
    return out


def get(record_id: str) -> Optional[dict]:
    """One staged write by id, or None."""
    for record in list_pending():
        if record.get("id") == record_id:
            return record
    return None


def discard(record_id: str) -> bool:
    """Drop a staged write without applying it."""
    for k in KINDS:
        path = pending_dir(k) / f"{record_id}.json"
        try:
            path.unlink()
            logger.info("Discarded pending write %s", record_id)
            return True
        except FileNotFoundError:
            continue
        except OSError as exc:
            logger.warning("Could not discard %s: %s", record_id, exc)
            return False
    return False


def apply(record_id: str) -> dict:
    """Commit a staged write by replaying it through the real store.

    Replaying the original operation -- rather than writing a rendered diff --
    means an approved write lands exactly the way an unreviewed one did.
    """
    record = get(record_id)
    if record is None:
        return {"success": False, "error": f"No pending write {record_id!r}."}
    if record.get("kind") != "memory":
        return {"success": False,
                "error": f"Applying {record.get('kind')!r} writes is not supported yet."}

    from tools.memory_tool import MemoryStore

    store = MemoryStore()
    store.load_from_disk()
    action = record.get("action")
    target = record.get("target") or "memory"
    try:
        if action == "add":
            result = store.add(target, record.get("content") or "")
        elif action == "replace":
            result = store.replace(target, record.get("old_text") or "",
                                   record.get("content") or "")
        elif action == "remove":
            result = store.remove(target, record.get("old_text") or "")
        else:
            return {"success": False, "error": f"Unknown staged action {action!r}."}
    except Exception as exc:
        return {"success": False, "error": f"Applying {record_id} failed: {exc}"}

    if isinstance(result, dict) and result.get("success") is False:
        return result
    discard(record_id)
    return {"success": True, "applied": record_id, "result": result}
