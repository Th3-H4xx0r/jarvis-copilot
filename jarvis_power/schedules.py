"""Pausing a Power integration's schedules while it's off, and only those it paused."""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def _list_jobs() -> list[dict]:
    from cron.jobs import list_jobs
    return list_jobs(include_disabled=True)


def _set_enabled(job_id: str, enabled: bool) -> None:
    from cron.jobs import update_job
    update_job(job_id, {"enabled": enabled})


def pause(space_id: str) -> list[str]:
    """Disable every enabled job that belongs to ``space_id``. Returns the ids it disabled."""
    paused = []
    for job in _list_jobs():
        owner = str(job.get("integration") or "").strip().lower()
        if owner == space_id and job.get("enabled", True):
            try:
                _set_enabled(job["id"], False)
                paused.append(job["id"])
            except Exception:
                logger.exception("power: could not pause schedule %s", job.get("id"))
    return paused


def restore(job_ids: list[str]) -> None:
    """Re-enable exactly the jobs :func:`pause` disabled (ones that still exist)."""
    existing = {job["id"] for job in _list_jobs()}
    for job_id in job_ids:
        if job_id in existing:
            try:
                _set_enabled(job_id, True)
            except Exception:
                logger.exception("power: could not restore schedule %s", job_id)
