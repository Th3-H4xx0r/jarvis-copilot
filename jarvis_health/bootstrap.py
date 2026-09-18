"""Jarvis Health exists whether or not anyone asked.

Every eligible wearable joins the one shared integration the moment the phone's
roster mentions it — health analysis is on by default, and the integration
cannot be deleted, only paused, re-tuned, or left alone. Nothing gets an
integration of its own any more.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Optional

from .sources import ELIGIBLE_KINDS
from .store import SHARED_NAME, SHARED_SPACE, HealthStore

logger = logging.getLogger(__name__)

#: How a settings frequency becomes a cron schedule string.
FREQUENCIES = {
    "hourly": "every 1h",
    "every 6 hours": "every 6h",
    "every 12 hours": "every 12h",
    "daily": "every 24h",
    "manual": "every 24h",
}


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


def ensure_health_integration(roster: list[dict[str, Any]]) -> dict:
    """Every eligible wearable joins Jarvis Health. Returns the space and its roster."""
    from .migrate import migrate_wearable_spaces

    migrate_wearable_spaces()
    store = HealthStore(SHARED_SPACE)
    for entry in roster or []:
        kind = str(entry.get("kind") or "").strip().lower()
        device_id = str(entry.get("device_id") or entry.get("deviceID") or "").strip()
        if kind not in ELIGIBLE_KINDS or not device_id:
            continue
        # Two identities and a zone: the wearable itself, the phone whose bridge
        # reaches it, and the timezone its days are bucketed in.
        store.upsert_device({
            "kind": kind,
            "device_id": device_id,
            "name": entry.get("name") or kind.title(),
            "bridge_device_id": entry.get("bridge_device_id") or entry.get("phone_id") or "",
            "timezone": entry.get("timezone") or "",
        })
    ensure_schedule(store.settings())
    return {"space": SHARED_SPACE, "devices": store.roster()}


#: The runner script. The scheduler runs a *file* in HERMES_HOME/scripts with
#: no arguments and no shell, so a command line with flags silently never
#: executes — which is why nothing is passed and the runner reads the roster.
_SCRIPT_TEMPLATE = "\n".join([
    '#!/usr/bin/env python3',
    "# Runs Jarvis Health. Written by jarvis_health.bootstrap.",
    '#',
    '# Regenerated whenever the settings change — edit the settings, not this',
    '# file. The cron scheduler execs a file inside HERMES_HOME/scripts with the',
    '# current interpreter, no shell and no arguments.',
    'import json',
    'import sys',
    '',
    'sys.path.insert(0, {repo!r})',
    '',
    'from jarvis_health.runner import run',
    '',
    "out = run(trigger='cron')",
    'print(json.dumps(out, default=str))',
    "sys.exit(0 if not out.get('error') else 1)",
    '',
])

_SCRIPT_NAME = "health_jarvis_health.py"


def _write_runner_script() -> Optional[str]:
    """Put the no-argument runner in HERMES_HOME/scripts."""
    try:
        from cron.scheduler import _get_hermes_home

        scripts = Path(_get_hermes_home()) / "scripts"
    except Exception:
        scripts = Path.home() / ".jarviscopilot" / "scripts"
    try:
        scripts.mkdir(parents=True, exist_ok=True)
        (scripts / _SCRIPT_NAME).write_text(_SCRIPT_TEMPLATE.format(repo=str(Path(__file__).resolve().parents[1])))
        return _SCRIPT_NAME
    except OSError as exc:
        logger.warning("health: could not write the runner script: %s", exc)
        return None


def ensure_schedule(settings: dict) -> Optional[dict]:
    """Create or re-point the one cron job that runs Jarvis Health."""
    try:
        import cron.jobs as jobs
    except Exception:  # pragma: no cover - cron is always present in the app
        return None

    script = _write_runner_script()
    if not script:
        return None
    schedule = schedule_for(settings.get("frequency"))
    enabled = bool(settings.get("enabled", True)) and (settings.get("frequency") or "") != "manual"

    existing = next((j for j in jobs.load_jobs() if str(j.get("integration") or "") == SHARED_SPACE), None)
    if existing:
        return jobs.update_job(
            existing["id"],
            {"schedule": schedule, "script": script, "enabled": enabled, "integration": SHARED_SPACE},
        )

    job = jobs.create_job(
        prompt=None,
        schedule=schedule,
        name=SHARED_NAME,
        script=script,
        no_agent=True,
        integration=SHARED_SPACE,
        deliver="local",
    )
    if job and not enabled:
        jobs.update_job(job["id"], {"enabled": False})
        job["enabled"] = False
    return job
