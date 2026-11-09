"""security_* tools — Jarvis's read-only view of the Security Advisor.

They read the webui's /api/security over the host-signed loopback, so they work
from any process. There is no tool to change settings, clear the log, undo a
block or answer an alert: an injected request must not be able to weaken the
watcher. Those happen on the Security page from a paired device.
"""
from __future__ import annotations

import json
import re
import urllib.parse
from datetime import datetime, timedelta, timezone

STATUS_SCHEMA = {
    "name": "security_status",
    "description": (
        "The Security Advisor's current state: 'quiet' or 'alerts', how many alerts are open, "
        "how many IPs are blocked, the last security event, and whether the SSH watch, file watch "
        "and the tamper-evident event log are working. Read-only."
    ),
    "parameters": {"type": "object", "properties": {}},
}

EVENTS_SCHEMA = {
    "name": "security_events",
    "description": (
        "Security events from Pranav's devices, the server and the agent (sign-in failures, "
        "pairings, SSH logins, file changes, blocked tool calls, ...), newest first, each with the "
        "outcome the rules gave it: ignore, digest, alert or block. Read-only."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "since": {"type": "string",
                      "description": "ISO time (2026-11-08T00:00:00Z) or a span like 24h or 7d."},
            "kind": {"type": "string", "description": "Event kind(s), comma-separated, e.g. ssh.accepted"},
            "outcome": {"type": "string", "enum": ["ignore", "digest", "alert", "block"]},
            "limit": {"type": "integer", "description": "At most 100 (default 50)."},
        },
    },
}


def _since(value: str) -> str:
    value = (value or "").strip()
    m = re.fullmatch(r"(\d+)\s*([hd])", value, re.I)
    if m:
        n, unit = int(m.group(1)), m.group(2).lower()
        delta = timedelta(hours=n) if unit == "h" else timedelta(days=n)
        return (datetime.now(timezone.utc) - delta).strftime("%Y-%m-%dT%H:%M:%SZ")
    return value


def _get(path: str) -> str:
    from tools.chrome_device_tool import _api_request
    res = _api_request("GET", path, timeout=15.0)
    if isinstance(res, dict) and res.get("_error"):
        return json.dumps({"error": f"Security Advisor unavailable: {res['_error']}"})
    return json.dumps(res)


def security_status(args, **kw) -> str:
    return _get("/api/security/status")


def security_events(args, **kw) -> str:
    args = args or {}
    try:
        limit = int(args.get("limit") or 50)
    except (TypeError, ValueError):
        limit = 50
    query = {"limit": str(min(max(limit, 1), 100))}
    for key in ("kind", "outcome"):
        if args.get(key):
            query[key] = str(args[key])
    if args.get("since"):
        query["since"] = _since(str(args["since"]))
    return _get("/api/security/events?" + urllib.parse.urlencode(query))


def available() -> bool:
    return True


TOOLS = [
    ("security_status", STATUS_SCHEMA, security_status, "🛡️"),
    ("security_events", EVENTS_SCHEMA, security_events, "🛡️"),
]
