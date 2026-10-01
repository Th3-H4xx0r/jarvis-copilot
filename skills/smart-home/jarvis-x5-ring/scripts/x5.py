#!/usr/bin/env python3
"""JarvisCopilot — X5 smart ring SDK and CLI.

The Jarvis iOS app holds the X5's Bluetooth link and advertises its commands as
``x5_*`` device skills over the device bridge — the same JSON the Colmi R12's
``ring_*`` skills return, plus gestures and workouts. This module wraps the devices
skill's host-signed webui client so scripts, cron jobs and automations get one typed
call per skill and plain JSON back. Stdlib only, Python 3.10+.

CLI (JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure):

    python3 x5.py status
    python3 x5.py day --metrics sleep,heart_rate --detail
    python3 x5.py measure spo2
    python3 x5.py workout start --sport walk
    python3 x5.py gesture-mode jarvis --touch-awake always
    python3 x5.py gesture-action swipe_up --prompt "What's next on my calendar?"
    python3 x5.py --device iphone history --days 14

Python:

    from x5 import X5Ring, X5Error
    ring = X5Ring()                    # finds the device offering x5_get_status
    sleep = ring.day(metrics=["sleep"])["summary"]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import types
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, NoReturn

STATUS_SKILL = "x5_get_status"

METRICS = ("activity", "sleep", "heart_rate", "spo2", "hrv", "stress", "temperature")
MEASUREMENTS = ("heart_rate", "spo2", "temperature")
MONITORED_METRICS = ("heart_rate", "hrv", "spo2")
WORKOUT_ACTIONS = ("start", "pause", "resume", "end", "status")
GESTURE_MODES = ("jarvis", "short_videos", "music", "camera", "off")
TOUCH_AWAKE = ("1", "5", "30", "always")
# tap is the ring's single click, double_tap its double click.
GESTURES = ("swipe_up", "swipe_down", "swipe_left", "swipe_right", "tap", "double_tap",
            "long_press", "hold_5s", "hold_10s")
PROFILE_FIELDS = ("sex", "age", "height_cm", "weight_kg", "stride_cm")

# The phone answers every skill within 25 s of receiving it; the rest covers waking a
# backgrounded app by push before that clock starts.
DEFAULT_TIMEOUT = 45.0
# The HTTP request outlives the invoke so the server's own timeout error comes back.
HTTP_GRACE = 5.0

_HERE = Path(__file__).resolve()
_DEVICES_REL = Path("skills", "jarviscopilot", "devices", "scripts", "devices.py")
_DEVICE_ID = re.compile(r"[0-9a-f]{32}")  # pairing ids are uuid4().hex
_loaded_devices: dict[Path, types.ModuleType] = {}


class X5Error(RuntimeError):
    """The X5 call could not be made, or the server, phone or ring refused it."""


# ── devices skill ────────────────────────────────────────────────────────────

def _devices_candidates() -> list[Path]:
    """Where the devices skill's devices.py may live, in the order they are tried."""
    candidates = [_HERE.parents[3] / "jarviscopilot" / "devices" / "scripts" / "devices.py"]
    checkout = os.environ.get("JARVISCOPILOT_DIR", "").strip()
    if checkout:
        candidates.append(Path(checkout).expanduser() / _DEVICES_REL)
    hermes_home = os.environ.get("HERMES_HOME", "").strip()
    if hermes_home:
        candidates.append(Path(hermes_home).expanduser() / _DEVICES_REL)
    candidates.append(Path.home() / ".jarviscopilot" / _DEVICES_REL)
    return list(dict.fromkeys(candidates))


def load_devices_module() -> types.ModuleType:
    """Imports devices.py for its host-signed ``_http(method, path, body, timeout)`` client."""
    candidates = _devices_candidates()
    for candidate in candidates:
        if not candidate.is_file():
            continue
        resolved = candidate.resolve()
        if resolved in _loaded_devices:
            return _loaded_devices[resolved]
        spec = importlib.util.spec_from_file_location("jarviscopilot_devices_skill", resolved)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except Exception as exc:
            raise X5Error(f"could not load {resolved}: {exc}") from exc
        if not callable(getattr(module, "_http", None)):
            raise X5Error(f"{resolved} has no _http client; update the devices skill")
        _loaded_devices[resolved] = module
        return module
    raise X5Error(
        "could not find the devices skill's devices.py (looked in: "
        + ", ".join(str(path) for path in candidates)
        + "). Install the jarviscopilot/devices skill or set JARVISCOPILOT_DIR to the JarvisCopilot checkout."
    )


# ── helpers ──────────────────────────────────────────────────────────────────

def _compact(values: dict[str, Any]) -> dict[str, Any]:
    """Drops unset (None) arguments, including inside nested objects; empty objects go too."""
    out: dict[str, Any] = {}
    for key, value in values.items():
        if isinstance(value, dict):
            value = _compact(value) or None
        if value is not None:
            out[key] = value
    return out


def _metric_list(metrics: str | Iterable[str] | None) -> list[str] | None:
    """Accepts a list of metric names or a comma-separated string."""
    if metrics is None:
        return None
    names = metrics.split(",") if isinstance(metrics, str) else metrics
    cleaned = [str(name).strip() for name in names if str(name).strip()]
    return cleaned or None


def _touch_awake(value: int | str | None) -> int | str | None:
    """Minutes as a number, or the word ``always``."""
    if value is None:
        return None
    text = str(value).strip().lower()
    if text not in TOUCH_AWAKE:
        raise X5Error(f"touch_awake must be one of {', '.join(TOUCH_AWAKE)}")
    return text if text == "always" else int(text)


def _failure(status: int, data: Any) -> str:
    """The most useful error text from a failed webui reply."""
    text = ""
    if isinstance(data, dict):
        text = str(data.get("error") or data.get("detail") or "")
    if status < 0:
        return "could not reach the Jarvis web UI" + (f": {text}" if text else "")
    return text or f"HTTP {status}"


# ── SDK ──────────────────────────────────────────────────────────────────────

class X5Ring:
    """The X5 smart ring, reached through the paired phone that advertises its ``x5_*`` skills.

    ``device`` picks that phone: a paired device id, an id prefix, or a case-insensitive
    name substring. Omitted, the device offering ``x5_get_status`` is found on first use.
    ``transport`` stands in for devices._http: ``(method, path, body, timeout) -> (status, data)``.
    """

    def __init__(self, device: str | None = None, timeout: float = DEFAULT_TIMEOUT,
                 transport: Callable[..., tuple[int, Any]] | None = None) -> None:
        self.device = device.strip() if device and device.strip() else None
        self.timeout = float(timeout)
        self.device_id: str | None = None
        self._transport = transport

    # plumbing

    def _request(self, method: str, path: str, body: dict[str, Any] | None,
                 timeout: float) -> tuple[int, Any]:
        if self._transport is None:
            self._transport = load_devices_module()._http
        return self._transport(method, path, body, timeout)

    def resolve_device(self) -> str:
        """The bridge device id skills run on; looked up once, then cached."""
        if self.device_id is None:
            self.device_id = self._match(self.device) if self.device else self._discover()
        return self.device_id

    def _skill_rows(self) -> list[dict[str, Any]]:
        status, data = self._request("GET", "/api/devices/skills", None, self.timeout)
        if not 200 <= status < 300:
            raise X5Error("could not list device skills: " + _failure(status, data))
        rows = data.get("skills") if isinstance(data, dict) else None
        return [row for row in rows or [] if isinstance(row, dict) and row.get("device_id")]

    def _discover(self) -> str:
        ids = list(dict.fromkeys(
            str(row["device_id"]) for row in self._skill_rows() if row.get("name") == STATUS_SKILL))
        if not ids:
            raise X5Error(
                f"no online device offers {STATUS_SKILL}: the Jarvis iOS app must be paired and reachable, "
                "and the X5 connected once in the app with Share with Jarvis on")
        return self._most_reachable(ids) if len(ids) > 1 else ids[0]

    def _most_reachable(self, ids: list[str]) -> str:
        """Prefers an invokable phone holding a live bridge connection; keeps listing order otherwise."""
        status, data = self._request("GET", "/api/devices", None, self.timeout)
        rows = data.get("devices") if 200 <= status < 300 and isinstance(data, dict) else None
        state = {str(row.get("id")): row for row in rows or [] if isinstance(row, dict)}

        def rank(device_id: str) -> tuple[bool, bool]:
            row = state.get(device_id, {})
            return (not row.get("invokable", False), not row.get("bridge_connected", False))

        return sorted(ids, key=rank)[0]

    def _match(self, query: str) -> str:
        lowered = query.lower()
        if _DEVICE_ID.fullmatch(lowered):
            return lowered
        names: dict[str, str] = {}
        has_x5: set[str] = set()
        for row in self._skill_rows():
            device_id = str(row["device_id"])
            names.setdefault(device_id, str(row.get("device_name") or ""))
            if row.get("name") == STATUS_SKILL:
                has_x5.add(device_id)
        matches = [d for d in names if d.lower().startswith(lowered) or lowered in names[d].lower()]
        if not matches:
            online = ", ".join(sorted(set(names.values()))) or "none"
            raise X5Error(f"no online device matching {query!r} (online: {online})")

        def rank(device_id: str) -> tuple[int, bool]:
            how = 0 if device_id.lower() == lowered else 1 if device_id.lower().startswith(lowered) else 2
            return (how, device_id not in has_x5)

        return sorted(matches, key=rank)[0]

    def invoke(self, skill: str, args: dict[str, Any] | None = None,
               timeout: float | None = None) -> dict[str, Any]:
        """Runs one ``x5_*`` skill; returns its result payload or raises X5Error."""
        wait = self.timeout if timeout is None else float(timeout)
        body = {"device_id": self.resolve_device(), "skill": skill, "args": _compact(args or {}), "timeout": wait}
        status, data = self._request("POST", "/api/devices/skills/invoke", body, wait + HTTP_GRACE)
        if not 200 <= status < 300 or not isinstance(data, dict) or data.get("ok") is False:
            raise X5Error(f"{skill}: {_failure(status, data)}")
        result = data.get("result")
        if isinstance(result, dict):
            if result.get("ok") is False:
                raise X5Error(f"{skill}: {_failure(status, result)}")
            return result
        return {"result": result}

    # skills

    def status(self) -> dict[str, Any]:
        """Connection, battery, firmware, gesture mode, last sync and measurement, today's summary."""
        return self.invoke("x5_get_status")

    def day(self, date: str | None = None, metrics: str | Iterable[str] | None = None,
            detail: bool = False) -> dict[str, Any]:
        """One day (``YYYY-MM-DD``, default today); ``detail`` adds series, sleep stages and step slots."""
        return self.invoke("x5_get_day", {"date": date, "metrics": _metric_list(metrics),
                                          "detail": True if detail else None})

    def health_day(self, date: str | None = None) -> dict[str, Any]:
        """One day in the Jarvis Health wire shape (``source: "x5ring"``)."""
        return self.invoke("x5_get_health_day", {"date": date})

    def history(self, days: int = 7, metrics: str | Iterable[str] | None = None) -> dict[str, Any]:
        """Per-day summaries for the last ``days`` days (1–30), today first."""
        return self.invoke("x5_get_history", {"days": days, "metrics": _metric_list(metrics)})

    def sync(self, days: int = 0) -> dict[str, Any]:
        """Pulls from the ring now: 0 = today only."""
        return self.invoke("x5_sync", {"days": days})

    def measure(self, type: str) -> dict[str, Any]:
        """Spot reading: heart_rate, spo2 or temperature. May answer ``status: measuring``."""
        return self.invoke("x5_measure", {"type": type}, timeout=max(self.timeout, DEFAULT_TIMEOUT))

    def workout(self, action: str, sport: str | None = None) -> dict[str, Any]:
        """start (with ``sport``), pause, resume, end or status of a workout on the ring."""
        if sport is not None and action != "start":
            raise X5Error("sport only goes with action start")
        return self.invoke("x5_workout", {"action": action, "sport": sport})

    def set_monitoring(self, metric: str, enabled: bool, interval_minutes: int | None = None) -> dict[str, Any]:
        """Automatic background measurement for heart_rate, hrv (with stress) or spo2."""
        return self.invoke("x5_set_monitoring", {"metric": metric, "enabled": bool(enabled),
                                                 "interval_minutes": interval_minutes})

    def set_gesture_mode(self, mode: str, touch_awake: int | str | None = None) -> dict[str, Any]:
        """What the touch panel does (jarvis, short_videos, music, camera, off) and how long it stays awake."""
        return self.invoke("x5_set_gesture_mode", {"mode": mode, "touch_awake": _touch_awake(touch_awake)})

    def set_gesture_action(self, gesture: str, prompt: str | None = None, skill: str | None = None,
                           arguments: dict[str, Any] | None = None, none: bool = False) -> dict[str, Any]:
        """What one gesture runs in jarvis mode: a ``prompt``, a ``skill`` with ``arguments``, or ``none``."""
        chosen = [name for name, given in (("prompt", prompt is not None), ("skill", skill is not None),
                                           ("none", none is True)) if given]
        if len(chosen) != 1:
            raise X5Error("give exactly one of prompt, skill (with optional arguments) or none")
        if arguments is not None and skill is None:
            raise X5Error("arguments only go with skill")
        return self.invoke("x5_set_gesture_action", {
            "gesture": gesture, "prompt": prompt, "skill": skill,
            "arguments": dict(arguments) if arguments else None, "none": True if none else None,
        })

    def find(self) -> dict[str, Any]:
        """Makes the ring vibrate."""
        return self.invoke("x5_find")

    def set_profile(self, **profile: Any) -> dict[str, Any]:
        """sex (male/female), age, height_cm, weight_kg, stride_cm; the rest keep their values."""
        unknown = sorted(set(profile) - set(PROFILE_FIELDS))
        if unknown:
            raise X5Error(f"unknown profile field(s) {', '.join(unknown)}; use {', '.join(PROFILE_FIELDS)}")
        args = _compact(profile)
        if not args:
            raise X5Error(f"give at least one profile field: {', '.join(PROFILE_FIELDS)}")
        return self.invoke("x5_set_profile", args)

    def restart(self) -> dict[str, Any]:
        """Restarts the ring (its data is kept); the link drops for a few seconds."""
        return self.invoke("x5_restart")

    def log(self, limit: int | None = None) -> dict[str, Any]:
        """The ring's recent command and gesture log, decoded, newest first."""
        return self.invoke("x5_get_log", {"limit": limit})


# ── CLI ──────────────────────────────────────────────────────────────────────

def _metrics_csv(text: str) -> list[str]:
    names = [name.strip() for name in text.split(",") if name.strip()]
    if not names or any(name not in METRICS for name in names):
        raise argparse.ArgumentTypeError("metrics must be a comma-separated list of: " + ", ".join(METRICS))
    return names


def _key_value(text: str) -> tuple[str, str]:
    key, sep, value = text.partition("=")
    if not sep or not key.strip():
        raise argparse.ArgumentTypeError(f"{text!r} is not key=value")
    return key.strip(), value


class _Parser(argparse.ArgumentParser):
    """Usage errors keep the CLI contract: ``{"error": ...}`` on stderr and exit code 1."""

    def error(self, message: str) -> NoReturn:
        print(json.dumps({"error": f"{self.prog}: {message}"}), file=sys.stderr)
        sys.exit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="x5.py", description="Read and control the X5 smart ring through the paired phone. "
                                                "Prints JSON.")
    parser.add_argument("--device", help="paired device id or name substring (default: the device offering "
                                         "x5_get_status)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="seconds to wait for the phone (default 45)")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    sub.add_parser("status", help="connection, battery, gesture mode and today's summary")

    p = sub.add_parser("day", help="one day's summary; --detail adds series, sleep stages and step slots")
    p.add_argument("--date", help="YYYY-MM-DD (default today)")
    p.add_argument("--metrics", type=_metrics_csv, help="comma-separated: " + ",".join(METRICS))
    p.add_argument("--detail", action="store_true")

    p = sub.add_parser("health-day", help="one day in the Jarvis Health wire shape")
    p.add_argument("--date", help="YYYY-MM-DD (default today)")

    p = sub.add_parser("history", help="daily summaries for recent days, today first")
    p.add_argument("--days", type=int, default=7, help="1-30 (default 7)")
    p.add_argument("--metrics", type=_metrics_csv, help="comma-separated: " + ",".join(METRICS))

    p = sub.add_parser("sync", help="pull stored data from the ring now")
    p.add_argument("--days", type=int, default=0, help="0 = today only (default 0)")

    p = sub.add_parser("measure", help="take a spot reading now (the ring must be worn)")
    p.add_argument("type", choices=MEASUREMENTS)

    p = sub.add_parser("workout", help="start, pause, resume, end or read a workout on the ring")
    p.add_argument("action", choices=WORKOUT_ACTIONS)
    p.add_argument("--sport", help="for start: run, walk, cycling, hiking, yoga, ... (default run)")

    p = sub.add_parser("monitoring", help="turn automatic background measurement on or off")
    p.add_argument("metric", choices=MONITORED_METRICS)
    p.add_argument("state", choices=("on", "off"))
    p.add_argument("--interval", type=int, help="minutes between readings")

    p = sub.add_parser("gesture-mode", help="what the touch panel does, and how long it stays awake")
    p.add_argument("mode", choices=GESTURE_MODES)
    p.add_argument("--touch-awake", dest="touch_awake", choices=TOUCH_AWAKE,
                   help="minutes the panel stays awake, or always (while connected)")

    p = sub.add_parser("gesture-action", help="what one gesture runs while the mode is jarvis")
    p.add_argument("gesture", choices=GESTURES)
    action = p.add_mutually_exclusive_group(required=True)
    action.add_argument("--prompt", help="ask Jarvis this")
    action.add_argument("--skill", help="run this skill (with --arg key=value)")
    action.add_argument("--none", action="store_true", help="the gesture does nothing")
    p.add_argument("--arg", dest="arguments", type=_key_value, action="append", metavar="KEY=VALUE",
                   help="an argument for --skill; repeatable")

    sub.add_parser("find", help="make the ring vibrate")

    p = sub.add_parser("profile", help="body profile; unspecified fields keep their values")
    p.add_argument("--sex", choices=("male", "female"))
    p.add_argument("--age", type=int)
    p.add_argument("--height-cm", dest="height_cm", type=int)
    p.add_argument("--weight-kg", dest="weight_kg", type=int)
    p.add_argument("--stride-cm", dest="stride_cm", type=int)

    sub.add_parser("restart", help="restart the ring (keeps its data)")

    p = sub.add_parser("log", help="the ring's recent command and gesture log")
    p.add_argument("--limit", type=int, help="entries, newest first")
    return parser


def _run(ring: X5Ring, args: argparse.Namespace) -> dict[str, Any]:
    command = args.command
    if command == "status":
        return ring.status()
    if command == "day":
        return ring.day(date=args.date, metrics=args.metrics, detail=args.detail)
    if command == "health-day":
        return ring.health_day(date=args.date)
    if command == "history":
        return ring.history(days=args.days, metrics=args.metrics)
    if command == "sync":
        return ring.sync(days=args.days)
    if command == "measure":
        return ring.measure(args.type)
    if command == "workout":
        return ring.workout(args.action, sport=args.sport)
    if command == "monitoring":
        return ring.set_monitoring(args.metric, args.state == "on", interval_minutes=args.interval)
    if command == "gesture-mode":
        return ring.set_gesture_mode(args.mode, touch_awake=args.touch_awake)
    if command == "gesture-action":
        return ring.set_gesture_action(args.gesture, prompt=args.prompt, skill=args.skill,
                                       arguments=dict(args.arguments) if args.arguments else None,
                                       none=args.none)
    if command == "find":
        return ring.find()
    if command == "profile":
        return ring.set_profile(**{name: getattr(args, name) for name in PROFILE_FIELDS})
    if command == "restart":
        return ring.restart()
    if command == "log":
        return ring.log(limit=args.limit)
    raise X5Error(f"unknown command {command!r}")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = _run(X5Ring(device=args.device, timeout=args.timeout), args)
    except X5Error as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
