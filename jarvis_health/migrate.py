"""One-time move from a space per wearable to the shared Jarvis Health space.

Idempotent: a moved space is gone, so a second run finds nothing. Protection
stops a *user* deleting a health space; the migration is the one caller let
past it, because it has just copied everything the space held.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Callable, Optional

from .store import SHARED_SPACE, HealthStore, device_key_for

logger = logging.getLogger(__name__)

#: What the person chose in the old space and keeps in the shared one.
_CARRIED = ("enabled", "model", "provider", "frequency", "quiet_hours", "rules", "goals",
            "temperature_unit", "profile")

#: A record's own columns: `records()` returns them flattened into the body,
#: and `append()` refuses a body that carries them.
_RECORD_COLUMNS = ("id", "ts", "source")


def _remove_legacy_schedule(space_id: str) -> None:
    """The old space's cron job and runner script, so it never runs again."""
    try:
        import cron.jobs as jobs
    except Exception:  # pragma: no cover - cron is always present in the app
        return
    for job in list(jobs.load_jobs()):
        if str(job.get("integration") or "") == space_id:
            jobs.remove_job(job["id"])
    try:
        from cron.scheduler import _get_hermes_home

        (Path(_get_hermes_home()) / "scripts" / f"health_{space_id.replace('-', '_')}.py").unlink(missing_ok=True)
    except Exception:
        pass


def migrate_wearable_spaces(remove_schedule: Optional[Callable[[str], None]] = None) -> dict:
    """Fold every `wearable-*` space into Jarvis Health. Returns what moved."""
    from jarvis_registry.store import shared

    registry = shared()
    remove_schedule = remove_schedule or _remove_legacy_schedule
    legacy = sorted(s["id"] for s in registry.spaces(include_archived=True)
                    if str(s.get("id", "")).startswith("wearable-"))
    if not legacy:
        return {"moved": []}

    store = HealthStore(SHARED_SPACE)
    first_ever = not (store.settings().get("migrated_from") or [])
    moved: list[str] = []
    for space_id in legacy:
        old = registry.open(space_id)
        settings = old.get("settings") or {}
        kind = settings.get("kind") or "ring"
        device_id = settings.get("device_id") or ""
        key = device_key_for(kind, device_id) if device_id else space_id[len("wearable-"):]

        # The first space's choices become the shared ones; later spaces only
        # bring their device.
        if first_ever and not moved:
            carried = {k: settings[k] for k in _CARRIED if k in settings}
            # The rule used to watch a re-weighted score; it now watches the
            # battery, a different number on a different scale, so no old
            # threshold — default or chosen — still means what it meant.
            rule = (carried.get("rules") or {}).get("health_low")
            if isinstance(rule, dict):
                rule["threshold"] = 25
            store.put_settings(carried)
        store.upsert_device({"key": key, "kind": kind, "device_id": device_id,
                             "name": settings.get("device_name") or kind.title(),
                             "bridge_device_id": settings.get("bridge_device_id") or "",
                             "timezone": settings.get("timezone") or ""})

        for doc in old.documents():
            name = str(doc.get("key", ""))
            if name.startswith("day-"):
                store._space.put(f"day-{key}-{name[4:]}", old.get(name))
            elif (name.startswith("scores-") or name in ("baseline", "held_alerts")) \
                    and store._space.get(name) is None:
                store._space.put(name, old.get(name))
        for record in old.records("alerts", limit=1000, newest_first=False):
            body = {k: v for k, v in record.items() if k not in _RECORD_COLUMNS}
            store._space.append("alerts", body, ts=record.get("ts"), source="migration")

        remove_schedule(space_id)
        registry.delete_space(space_id)
        moved.append(space_id)
        logger.info("health: moved %s into %s", space_id, SHARED_SPACE)

    done = list(store.settings().get("migrated_from") or [])
    store.put_settings({"migrated_from": sorted(set(done) | set(moved))})
    return {"moved": moved}
