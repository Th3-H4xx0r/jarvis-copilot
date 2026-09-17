"""Creating the integration a wearable gets whether or not anyone asked.

Eligible devices get a protected space and a schedule the moment the roster
mentions them, so health analysis is on by default and cannot be deleted —
only paused, re-tuned, or left alone.
"""
from __future__ import annotations

import logging
import re
from typing import Any, Optional

from .sources import ELIGIBLE_KINDS
from .store import HealthStore, space_id_for

logger = logging.getLogger(__name__)

#: How a settings frequency becomes a cron schedule string.
FREQUENCIES = {
    "hourly": "every 1h",
    "every 6 hours": "every 6h",
    "every 12 hours": "every 12h",
    "daily": "every 24h",
    "manual": "every 24h",
}


def _space_name(device_name: str) -> str:
    """A registry space name: letters, digits, space, _ . & - and nothing else."""
    cleaned = re.sub(r"[^A-Za-z0-9 _.&-]", " ", f"Health {device_name}").strip()
    return re.sub(r"\s+", " ", cleaned)[:64] or "Health"


def schedule_for(frequency: str) -> str:
    """A settings frequency as a schedule `cron.jobs.parse_schedule` accepts.

    Intervals only: cron expressions would need `croniter`, which this server
    does not carry, so the presets are spacings rather than times of day.
    """
    frequency = (frequency or "").strip().lower()
    if frequency in FREQUENCIES:
        return FREQUENCIES[frequency]
    if frequency.startswith("every "):
        return frequency
    return FREQUENCIES["every 6 hours"]


def ensure_wearable_integrations(roster: list[dict[str, Any]]) -> list[str]:
    """One protected space per eligible wearable. Returns the space ids."""
    created: list[str] = []
    for entry in roster or []:
        kind = str(entry.get("kind") or "").strip().lower()
        device_id = str(entry.get("device_id") or entry.get("deviceID") or "").strip()
        if kind not in ELIGIBLE_KINDS or not device_id:
            continue

        space_id = space_id_for(kind, device_id)
        name = entry.get("name") or kind.title()
        store = HealthStore(space_id, name=_space_name(name))
        settings = store.put_settings({"device_id": device_id, "kind": kind, "device_name": name})
        ensure_schedule(space_id, settings, device_id=device_id, kind=kind)
        created.append(space_id)
    return created


def ensure_schedule(space_id: str, settings: dict, device_id: str, kind: str = "ring") -> Optional[dict]:
    """Create or re-point the cron job that runs this integration's analysis."""
    try:
        import cron.jobs as jobs
    except Exception:  # pragma: no cover - cron is always present in the app
        return None

    script = f"python3 -m jarvis_health.runner --space {space_id} --device {device_id} --kind {kind}"
    schedule = schedule_for(settings.get("frequency"))
    enabled = bool(settings.get("enabled", True)) and (settings.get("frequency") or "") != "manual"

    existing = next(
        (j for j in jobs.load_jobs() if str(j.get("integration") or "") == space_id),
        None,
    )
    if existing:
        return jobs.update_job(
            existing["id"],
            {"schedule": schedule, "script": script, "enabled": enabled, "integration": space_id},
        )

    job = jobs.create_job(
        prompt=None,
        schedule=schedule,
        name=f"Health · {settings.get('device_name') or kind.title()}",
        script=script,
        no_agent=True,
        integration=space_id,
        deliver="local",
    )
    if job and not enabled:
        jobs.update_job(job["id"], {"enabled": False})
        job["enabled"] = False
    return job
