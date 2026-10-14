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
    python3 health.py habits                        # quit habits: time since the last relapse, goals
    python3 health.py habit-relapse --habit vaping [--at 2026-10-14T03:00:00Z]   # log one

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


# ── quit habits ──────────────────────────────────────────────────────────────

def find_habit(ref: str):
    """(habit, None) by id, else by name — exact, then one partial match; (None, why) otherwise."""
    status, data = request("GET", f"{BASE}/habits")
    if status != 200:
        return None, data.get("error") or "could not read habits"
    found = data.get("habits") or []
    key = ref.strip().casefold()
    for match in ([h for h in found if h.get("id") == ref],
                  [h for h in found if str(h.get("name", "")).casefold() == key],
                  [h for h in found if key in str(h.get("name", "")).casefold()]):
        if len(match) == 1:
            return match[0], None
        if len(match) > 1:
            break
    names = ", ".join(f"{h.get('name')} ({h.get('id')})" for h in found) or "none yet"
    return None, f"no single habit matches {ref!r}; habits: {names}"


def _write(path: str, body: dict) -> int:
    status, data = request("POST", path, body)
    return show(data) if status == 200 else fail(data.get("error") or f"could not write {path}")


def _goal(args, current=None) -> dict:
    """The habit's whole goal with the flags applied (a goal is replaced whole)."""
    goal = dict(current or {"streak_days": None, "limit": None})
    if args.streak_days is not None:
        goal["streak_days"] = args.streak_days or None
    if args.no_limit:
        goal["limit"] = None
    elif args.limit is not None:
        goal["limit"] = {"per": args.per, "count": args.limit}
    return goal


def cmd_habits(args) -> int:
    return get(f"{BASE}/habits")


def cmd_habit_create(args) -> int:
    body = {"name": args.name, "goal": _goal(args)}
    if args.started:
        body["started_at"] = args.started
    return _write(f"{BASE}/habits", {"habit": body})


def cmd_habit(args) -> int:
    habit, error = find_habit(args.habit)
    if habit is None:
        return fail(error)
    if args.command == "habit-days":
        return get(f"{BASE}/habits/days?id={habit['id']}&days={args.days}")
    if args.command == "habit-relapse":
        body = {"habit": habit["id"]}
        if args.at:
            body["at"] = args.at
        if args.note:
            body["note"] = args.note
        return _write(f"{BASE}/habits/relapse", body)
    if args.command == "habit-undo":
        return _write(f"{BASE}/habits/relapse/delete", {"habit": habit["id"], "latest": True})
    if args.command == "habit-delete":
        return _write(f"{BASE}/habits/delete", {"id": habit["id"]})
    change = {"id": habit["id"]}
    if args.name:
        change["name"] = args.name
    if args.started:
        change["started_at"] = args.started
    if args.streak_days is not None or args.limit is not None or args.no_limit:
        change["goal"] = _goal(args, habit.get("goal"))
    return _write(f"{BASE}/habits", {"habit": change})


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Wearable health scores and alerts.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("devices", help="the wearables feeding Jarvis Health")
    sub.add_parser("now", help="today: last night's bedtime to now")

    day = sub.add_parser("day", help="one day bedtime to bedtime, with scores and analysis")
    day.add_argument("--date", help="YYYY-MM-DD, default the day today belongs to")

    hist = sub.add_parser("history", help="a metric's history over a day, week, month, 6 months or year")
    hist.add_argument("--metric", required=True, choices=METRICS)
    hist.add_argument("--range", default="M", choices=("D", "W", "M", "6M", "Y"))
    hist.add_argument("--end", help="YYYY-MM-DD, default today")

    vit = sub.add_parser("vitals", help="spot readings: latest, usual ranges, trends, insights")
    vit.add_argument("--days", type=int, default=30)
    vit.add_argument("--end", help="YYYY-MM-DD, default today")

    sub.add_parser("run", help="run the analysis now")
    sub.add_parser("settings", help="read the settings")
    for name in ("runs", "alerts"):
        sub.add_parser(name, help=f"recent {name}").set_defaults(what=name)

    sub.add_parser("habits", help="quit habits: time since the last relapse, counts, goals")
    hd = sub.add_parser("habit-days", help="a habit's relapses per day")
    hd.add_argument("--habit", required=True, help="id or name")
    hd.add_argument("--days", type=int, default=30)
    hc = sub.add_parser("habit-create", help="start tracking a habit to quit")
    hc.add_argument("--name", required=True)
    hc.set_defaults(no_limit=False)
    hu = sub.add_parser("habit-update", help="rename a habit, move its quit date or change its goal")
    hu.add_argument("--habit", required=True, help="id or name")
    hu.add_argument("--name")
    hu.add_argument("--no-limit", action="store_true", help="drop the relapse limit")
    for p in (hc, hu):
        p.add_argument("--started", help="the quit date, a UTC instant (default now)")
        p.add_argument("--streak-days", type=int, help="target days without a relapse (0 clears it)")
        p.add_argument("--limit", type=int, help="at most this many relapses …")
        p.add_argument("--per", choices=("day", "month"), default="day", help="… a day or a month")
    hr = sub.add_parser("habit-relapse", help="log a relapse, now or --at")
    hr.add_argument("--habit", required=True, help="id or name")
    hr.add_argument("--at", help="a UTC instant, default now")
    hr.add_argument("--note")
    for name, text in (("habit-undo", "remove the latest relapse"),
                       ("habit-delete", "delete a habit and all its relapses")):
        sub.add_parser(name, help=text).add_argument("--habit", required=True, help="id or name")

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
        "habits": cmd_habits,
        "habit-create": cmd_habit_create,
        "habit-days": cmd_habit,
        "habit-update": cmd_habit,
        "habit-relapse": cmd_habit,
        "habit-undo": cmd_habit,
        "habit-delete": cmd_habit,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
