#!/usr/bin/env python3
"""JarvisCopilot — wearable health helper.

Stdlib only. Reads and drives the health integrations over the webui's local
API, so the agent can answer "how did I sleep" without touching the registry
or knowing which wearable is which.

Usage:
    python3 health.py devices                       # the wearables feeding Jarvis Health
    python3 health.py now                           # today: last night's bedtime to now
    python3 health.py day [--date 2026-09-16]       # one day bedtime to bedtime, with scores
    python3 health.py history --metric blood_glucose --range M   # a metric's W/M/6M/Y history
    python3 health.py vitals [--days 30]            # BP, glucose, blood fats, body comp, ECG: insights
    python3 health.py run                           # run the analysis now
    python3 health.py settings                      # read settings
    python3 health.py runs | alerts                 # recent runs / alerts

Exit codes: 0 success, 1 error (a JSON object on stderr).
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

from pathlib import Path


# Stdlib only, and no import from the repo: the installed copy of this skill
# lives under ~/.jarviscopilot/skills, where `jarvis_health` is not importable.
# The host carve-out is small enough to carry, exactly as devices.py does.
_STATE = Path(os.environ.get("HERMES_WEBUI_STATE_DIR") or (Path.home() / ".jarviscopilot" / "webui"))
#: Every wearable feeds the one shared integration.
SPACE = "jarvis-health"
BASE = f"/api/integrations/{SPACE}/health"
#: What `history --metric` takes (the server answers 400 for anything else).
METRICS = ("battery", "steps", "sleep", "sleep_debt", "heart_rate", "spo2", "hrv", "stress", "temperature",
           "exercise", "weight", "body_fat", "blood_pressure", "blood_glucose", "uric_acid", "cholesterol",
           "triglycerides", "hdl", "ldl", "bmi", "muscle_mass", "skeletal_muscle", "body_water", "bone_mass",
           "protein", "bmr", "ecg", "ecg_hrv", "ecg_qtc", "respiratory_rate")
_key_cache: dict = {"key": None}


def _cert() -> Path:
    """The webui's TLS cert, at HERMES_HOME/webui-tls/cert.pem when it serves HTTPS."""
    env_home = os.environ.get("HERMES_HOME", "").strip()
    home = Path(env_home) if env_home else (Path.home() / ".jarviscopilot")
    return home / "webui-tls" / "cert.pem"


def _origin() -> str:
    """Where the local webui listens: port 8787, TLS read from the cert on disk.

    A skill run from the gateway or a cron job does not inherit the webui's
    environment, so the scheme cannot come from HERMES_WEBUI_TLS_CERT alone.
    """
    override = os.environ.get("JC_WEBUI_URL")
    if override:
        return override.rstrip("/")
    host = os.environ.get("HERMES_WEBUI_HOST", "127.0.0.1")
    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    port = os.environ.get("HERMES_WEBUI_PORT", "8787")
    tls = bool(os.environ.get("HERMES_WEBUI_TLS_CERT")) or _cert().exists()
    return f"{'https' if tls else 'http'}://{host}:{port}"


def _signing_key():
    if _key_cache["key"] is None:
        try:
            _key_cache["key"] = (_STATE.expanduser().resolve() / ".signing_key").read_bytes()
        except OSError:
            return None
    return _key_cache["key"]


def request(method: str, path: str, body: dict | None = None, timeout: float = 45):
    """One loopback call to the webui, signed the way api/auth.py verifies."""
    payload = json.dumps(body or {}).encode() if body is not None else b""
    url = _origin() + path
    req = urllib.request.Request(url, data=payload or None, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    key = _signing_key()
    if key:
        stamp = int(time.time())
        message = f"{method}\n{path}\n{stamp}".encode()
        req.add_header("X-JC-Host-Sig", f"{stamp}.{hmac.new(key, message, hashlib.sha256).hexdigest()}")
    context = None
    if url.startswith("https://"):
        import ssl

        context = ssl._create_unverified_context()   # self-signed, loopback only
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=context) as response:
            return response.status, json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode() or "{}")
        except Exception:
            return exc.code, {"error": str(exc)}
    except Exception as exc:
        return 0, {"error": str(exc)}


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


def get(path: str, timeout: float = 45) -> int:
    status, data = request("GET", path, timeout=timeout)
    if status != 200:
        return fail(data.get("error") or f"could not read {path}")
    return show(data)


def cmd_devices(args) -> int:
    found = devices()
    return show({"devices": found}) if found else fail("no wearable has joined Jarvis Health yet")


def cmd_now(args) -> int:
    return get(f"{BASE}/now")


def cmd_day(args) -> int:
    if not args.date:
        status, data = request("GET", f"{BASE}/now")
        if status != 200:
            return fail(data.get("error") or "could not read today")
        args.date = data.get("date")
    return get(f"{BASE}/day?date={args.date}")


def cmd_history(args) -> int:
    query = f"metric={args.metric}&range={args.range}" + (f"&end={args.end}" if args.end else "")
    return get(f"{BASE}/history?{query}")


def cmd_vitals(args) -> int:
    return get(f"{BASE}/vitals?days={args.days}" + (f"&end={args.end}" if args.end else ""))


def cmd_run(args) -> int:
    status, data = request("POST", f"{BASE}/run", {"trigger": "agent"}, timeout=180)
    if status != 200:
        return fail(data.get("error") or "the run failed")
    return show(data)


def cmd_settings(args) -> int:
    return get(f"{BASE}/settings")


def cmd_stream(args) -> int:
    return get(f"{BASE}/{args.what}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Wearable health scores and alerts.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("devices", help="the wearables feeding Jarvis Health")
    sub.add_parser("now", help="today: last night's bedtime to now")

    day = sub.add_parser("day", help="one day bedtime to bedtime, with scores and analysis")
    day.add_argument("--date", help="YYYY-MM-DD, default the day today belongs to")

    hist = sub.add_parser("history", help="a metric's history over a week, month, 6 months or year")
    hist.add_argument("--metric", required=True, choices=METRICS)
    hist.add_argument("--range", default="M", choices=("W", "M", "6M", "Y"))
    hist.add_argument("--end", help="YYYY-MM-DD, default today")

    vit = sub.add_parser("vitals", help="spot readings: latest, usual ranges, trends, insights")
    vit.add_argument("--days", type=int, default=30)
    vit.add_argument("--end", help="YYYY-MM-DD, default today")

    sub.add_parser("run", help="run the analysis now")
    sub.add_parser("settings", help="read the settings")
    for name in ("runs", "alerts"):
        sub.add_parser(name, help=f"recent {name}").set_defaults(what=name)

    args = parser.parse_args(argv)
    handlers = {
        "devices": cmd_devices,
        "now": cmd_now,
        "day": cmd_day,
        "history": cmd_history,
        "vitals": cmd_vitals,
        "run": cmd_run,
        "settings": cmd_settings,
        "runs": cmd_stream,
        "alerts": cmd_stream,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
