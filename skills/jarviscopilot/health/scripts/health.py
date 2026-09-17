#!/usr/bin/env python3
"""JarvisCopilot — wearable health helper.

Stdlib only. Reads and drives the health integrations over the webui's local
API, so the agent can answer "how did I sleep" without touching the registry
or knowing which wearable is which.

Usage:
    python3 health.py devices                       # wearables with health analysis
    python3 health.py day                           # today's scores, first device
    python3 health.py day --date 2026-09-16 --device ring
    python3 health.py run                           # run the analysis now
    python3 health.py settings                      # read settings
    python3 health.py runs | alerts                 # recent runs / alerts

Exit codes: 0 success, 1 error (a JSON object on stderr).
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve()
for parent in ROOT.parents:
    if (parent / "jarvis_health").is_dir():
        sys.path.insert(0, str(parent))
        break

from jarvis_health.bridge import request  # noqa: E402


def fail(message: str) -> int:
    print(json.dumps({"error": message}), file=sys.stderr)
    return 1


def show(payload) -> int:
    print(json.dumps(payload, indent=2, default=str))
    return 0


def devices() -> list[dict]:
    status, data = request("GET", "/api/health/devices")
    if status != 200:
        return []
    return data.get("devices") or []


def pick(wanted: str | None) -> dict | None:
    found = devices()
    if not found:
        return None
    if not wanted:
        return found[0]
    wanted = wanted.lower()
    for device in found:
        if wanted in (device.get("kind", "").lower(), device.get("name", "").lower(),
                      device.get("space_id", "").lower(), device.get("device_id", "").lower()):
            return device
    return None


def today_for(device: dict) -> str:
    """The device's own local day, from the offset its last stored day carried."""
    status, data = request("GET", f"/api/integrations/{device['space_id']}/health/settings")
    offset = 0
    if status == 200:
        offset = int(((data.get("settings") or {}).get("utc_offset")) or 0)
    return (datetime.now(timezone.utc) + timedelta(seconds=offset)).strftime("%Y-%m-%d")


def cmd_devices(args) -> int:
    found = devices()
    return show({"devices": found}) if found else fail("no wearable has a health integration yet")


def cmd_day(args) -> int:
    device = pick(args.device)
    if not device:
        return fail("no matching wearable with health analysis")
    date = args.date or today_for(device)
    status, data = request("GET", f"/api/integrations/{device['space_id']}/health/day/{date}")
    if status != 200:
        return fail(data.get("error") or f"could not read {date}")
    return show({"device": device["name"], **data})


def cmd_run(args) -> int:
    device = pick(args.device)
    if not device:
        return fail("no matching wearable with health analysis")
    status, data = request(
        "POST",
        f"/api/integrations/{device['space_id']}/health/run",
        {"trigger": "agent"},
        timeout=180,
    )
    if status != 200:
        return fail(data.get("error") or "the run failed")
    return show(data)


def cmd_settings(args) -> int:
    device = pick(args.device)
    if not device:
        return fail("no matching wearable with health analysis")
    status, data = request("GET", f"/api/integrations/{device['space_id']}/health/settings")
    if status != 200:
        return fail(data.get("error") or "could not read the settings")
    return show(data)


def cmd_stream(args) -> int:
    device = pick(args.device)
    if not device:
        return fail("no matching wearable with health analysis")
    status, data = request("GET", f"/api/integrations/{device['space_id']}/health/{args.what}")
    if status != 200:
        return fail(data.get("error") or f"could not read {args.what}")
    return show(data)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Wearable health scores and alerts.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("devices", help="wearables with health analysis")

    day = sub.add_parser("day", help="scores and analysis for a local day")
    day.add_argument("--date", help="YYYY-MM-DD, default today on the device")
    day.add_argument("--device", help="kind, name or id; default the first")

    run = sub.add_parser("run", help="run the analysis now")
    run.add_argument("--device")

    settings = sub.add_parser("settings", help="read the settings")
    settings.add_argument("--device")

    for name in ("runs", "alerts"):
        stream = sub.add_parser(name, help=f"recent {name}")
        stream.add_argument("--device")
        stream.set_defaults(what=name)

    args = parser.parse_args(argv)
    handlers = {
        "devices": cmd_devices,
        "day": cmd_day,
        "run": cmd_run,
        "settings": cmd_settings,
        "runs": cmd_stream,
        "alerts": cmd_stream,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
