"""Creating the integration a wearable gets whether or not anyone asked.

Eligible devices get a protected space and a schedule the moment the roster
mentions them, so health analysis is on by default and cannot be deleted —
only paused, re-tuned, or left alone.
"""
from __future__ import annotations

import logging
import re
from pathlib import Path
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
        # Two identities and a zone: the wearable itself, the phone whose bridge
        # reaches it, and the timezone whose days this wearable's data is in.
        settings = store.put_settings({
            "device_id": device_id,
            "kind": kind,
            "device_name": name,
            "bridge_device_id": entry.get("bridge_device_id") or entry.get("phone_id") or "",
            "timezone": entry.get("timezone") or "",
        })
        ensure_schedule(space_id, settings, device_id=device_id, kind=kind)
        created.append(space_id)
    return created


#: The runner script written per integration. The scheduler runs a *file* in
#: HERMES_HOME/scripts with no arguments and no shell, so a command line with
#: flags silently never executes — the parameters are baked in instead.
_SCRIPT_TEMPLATE = "\n".join([
    '#!/usr/bin/env python3',
    "# Runs one wearable's health analysis. Written by jarvis_health.bootstrap.",
    '#',
    "# Regenerated whenever the integration's settings change — edit the settings,",
    '# not this file. The cron scheduler execs a file inside HERMES_HOME/scripts',
    '# with the current interpreter, no shell and no arguments, which is why the',
    '# space and the devices are written in rather than passed.',
    'import json',
    'import sys',
    '',
    'sys.path.insert(0, {repo!r})',
    '',
    'from jarvis_health.runner import run',
    'from jarvis_health.sources import source_for',
    '',
    "out = run({space_id!r}, source_for({kind!r}, {bridge!r}, {wearable!r}), trigger='cron')",
    'print(json.dumps(out, default=str))',
    "sys.exit(0 if not out.get('error') else 1)",
    '',
])


def _write_runner_script(space_id: str, settings: dict, wearable_id: str, kind: str) -> Optional[str]:
    """Put a no-argument runner for this integration in HERMES_HOME/scripts."""
    try:
        from cron.scheduler import _get_hermes_home

        scripts = Path(_get_hermes_home()) / "scripts"
    except Exception:
        scripts = Path.home() / ".jarviscopilot" / "scripts"

    name = f"health_{space_id.replace('-', '_')}.py"
    try:
        scripts.mkdir(parents=True, exist_ok=True)
        (scripts / name).write_text(_SCRIPT_TEMPLATE.format(
            repo=str(Path(__file__).resolve().parents[1]),
            space_id=space_id,
            kind=kind,
            bridge=settings.get("bridge_device_id") or "",
            wearable=wearable_id,
        ))
        return name
    except OSError as exc:
        logger.warning("health: could not write the runner script for %s: %s", space_id, exc)
        return None


def ensure_schedule(space_id: str, settings: dict, device_id: str, kind: str = "ring") -> Optional[dict]:
    """Create or re-point the cron job that runs this integration's analysis."""
    try:
        import cron.jobs as jobs
    except Exception:  # pragma: no cover - cron is always present in the app
        return None

    script = _write_runner_script(space_id, settings, device_id, kind)
    if not script:
        return None
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
