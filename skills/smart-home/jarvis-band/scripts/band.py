#!/usr/bin/env python3
"""JarvisCopilot — HBand (Veepoo) smart band SDK and CLI.

The Jarvis iOS app holds the band's Bluetooth link and advertises its commands as
``band_*`` device skills over the device bridge — the same day, history and status
JSON the Colmi R12's ``ring_*`` skills return, plus blood pressure, alerts, alarms,
sedentary reminders and workouts. This module wraps the devices skill's host-signed
webui client so scripts, cron jobs and automations get one typed call per skill and
plain JSON back. Stdlib only, Python 3.10+.

CLI (JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure):

    python3 band.py status
    python3 band.py day --metrics sleep,heart_rate,blood_pressure --detail
    python3 band.py measure blood_pressure
    python3 band.py workout start --sport walk
    python3 band.py alerts --calls on --messages on --apps WhatsApp,Telegram
    python3 band.py alarm add --time 06:45 --days mon,tue,wed,thu,fri
    python3 band.py sedentary on --interval 60 --start 09:00 --end 18:00
    python3 band.py --device iphone history --days 14

Python:

    from band import Band, BandError
    band = Band()                      # finds the device offering band_get_status
    pressure = band.day(metrics=["blood_pressure"])["summary"]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import time
import types
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, NoReturn

STATUS_SKILL = "band_get_status"

METRICS = ("activity", "sleep", "heart_rate", "spo2", "hrv", "temperature", "blood_pressure")
MEASUREMENTS = ("heart_rate", "spo2", "blood_pressure", "temperature", "stress", "blood_glucose",
                "blood_component", "body_composition", "ecg")
MONITORED_METRICS = ("heart_rate", "spo2", "blood_pressure", "temperature")
WORKOUT_ACTIONS = ("start", "pause", "resume", "end", "status")
ALARM_ACTIONS = ("list", "add", "delete")
DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
PROFILE_FIELDS = ("sex", "age", "height_cm", "weight_kg")

# The phone answers every skill within 25 s of receiving it; the rest covers waking a
# backgrounded app by push before that clock starts.
DEFAULT_TIMEOUT = 45.0
# The HTTP request outlives the invoke so the server's own timeout error comes back.
HTTP_GRACE = 5.0

_HERE = Path(__file__).resolve()
_DEVICES_REL = Path("skills", "jarviscopilot", "devices", "scripts", "devices.py")
_DEVICE_ID = re.compile(r"[0-9a-f]{32}")  # pairing ids are uuid4().hex
_CLOCK = re.compile(r"(\d{1,2}):(\d{2})")
_loaded_devices: dict[Path, types.ModuleType] = {}


class BandError(RuntimeError):
    """The band call could not be made, or the server, phone or band refused it."""


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
            raise BandError(f"could not load {resolved}: {exc}") from exc
        if not callable(getattr(module, "_http", None)):
            raise BandError(f"{resolved} has no _http client; update the devices skill")
        _loaded_devices[resolved] = module
        return module
    raise BandError(
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


def _names(values: str | Iterable[str] | None) -> list[str] | None:
    """A list of names, or a comma-separated string of them; blanks are dropped (the list may end empty)."""
    if values is None:
        return None
    names = values.split(",") if isinstance(values, str) else values
    return [str(name).strip() for name in names if str(name).strip()]


def _metric_list(metrics: str | Iterable[str] | None) -> list[str] | None:
    """Accepts a list of metric names or a comma-separated string."""
    return _names(metrics) or None


def _clock(value: str | None, field: str) -> str | None:
    """A 24-hour ``HH:MM``, zero-padded (``7:05`` → ``07:05``)."""
    if value is None:
        return None
    match = _CLOCK.fullmatch(str(value).strip())
    if not match or int(match.group(1)) > 23 or int(match.group(2)) > 59:
        raise BandError(f"{field} must be a 24-hour time HH:MM, not {value!r}")
    return f"{int(match.group(1)):02d}:{match.group(2)}"


def _days(values: str | Iterable[str] | None) -> list[str] | None:
    """Weekday names from mon..sun, in the order given, each once."""
    names = _names(values)
    if names is None:
        return None
    lowered = list(dict.fromkeys(name.lower() for name in names))
    unknown = [name for name in lowered if name not in DAYS]
    if unknown:
        raise BandError(f"unknown day(s) {', '.join(unknown)}; use {', '.join(DAYS)}")
    return lowered


def _failure(status: int, data: Any) -> str:
    """The most useful error text from a failed webui reply."""
    text = ""
    if isinstance(data, dict):
        text = str(data.get("error") or data.get("detail") or "")
    if status < 0:
        return "could not reach the Jarvis web UI" + (f": {text}" if text else "")
    return text or f"HTTP {status}"


# ── SDK ──────────────────────────────────────────────────────────────────────

class Band:
    """The HBand smart band, reached through the paired phone that advertises its ``band_*`` skills.

    ``device`` picks that phone: a paired device id, an id prefix, or a case-insensitive
    name substring. Omitted, the device offering ``band_get_status`` is found on first use.
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
            raise BandError("could not list device skills: " + _failure(status, data))
        rows = data.get("skills") if isinstance(data, dict) else None
        return [row for row in rows or [] if isinstance(row, dict) and row.get("device_id")]

    def _discover(self) -> str:
        ids = list(dict.fromkeys(
            str(row["device_id"]) for row in self._skill_rows() if row.get("name") == STATUS_SKILL))
        if not ids:
            raise BandError(
                f"no online device offers {STATUS_SKILL}: the Jarvis iOS app must be paired and reachable, "
                "and the band connected once in the app with Share with Jarvis on")
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
        has_band: set[str] = set()
        for row in self._skill_rows():
            device_id = str(row["device_id"])
            names.setdefault(device_id, str(row.get("device_name") or ""))
            if row.get("name") == STATUS_SKILL:
                has_band.add(device_id)
        matches = [d for d in names if d.lower().startswith(lowered) or lowered in names[d].lower()]
        if not matches:
            online = ", ".join(sorted(set(names.values()))) or "none"
            raise BandError(f"no online device matching {query!r} (online: {online})")

        def rank(device_id: str) -> tuple[int, bool]:
            how = 0 if device_id.lower() == lowered else 1 if device_id.lower().startswith(lowered) else 2
            return (how, device_id not in has_band)

        return sorted(matches, key=rank)[0]

    def invoke(self, skill: str, args: dict[str, Any] | None = None,
               timeout: float | None = None) -> dict[str, Any]:
        """Runs one ``band_*`` skill; returns its result payload or raises BandError."""
        wait = self.timeout if timeout is None else float(timeout)
        body = {"device_id": self.resolve_device(), "skill": skill, "args": _compact(args or {}), "timeout": wait}
        status, data = self._request("POST", "/api/devices/skills/invoke", body, wait + HTTP_GRACE)
        if not 200 <= status < 300 or not isinstance(data, dict) or data.get("ok") is False:
            raise BandError(f"{skill}: {_failure(status, data)}")
        result = data.get("result")
        if isinstance(result, dict):
            if result.get("ok") is False:
                raise BandError(f"{skill}: {_failure(status, result)}")
            return result
        return {"result": result}

    # skills

    def status(self) -> dict[str, Any]:
        """Connection, battery, firmware, wear, last sync and measurement, today's summary."""
        return self.invoke("band_get_status")

    def day(self, date: str | None = None, metrics: str | Iterable[str] | None = None,
            detail: bool = False) -> dict[str, Any]:
        """One day (``YYYY-MM-DD``, default today); ``detail`` adds series, sleep stages and readings."""
        return self.invoke("band_get_day", {"date": date, "metrics": _metric_list(metrics),
                                            "detail": True if detail else None})

    def health_day(self, date: str | None = None) -> dict[str, Any]:
        """One day in the Jarvis Health wire shape (``source: "band"``)."""
        return self.invoke("band_get_health_day", {"date": date})

    def history(self, days: int = 7, metrics: str | Iterable[str] | None = None) -> dict[str, Any]:
        """Per-day summaries for the last ``days`` days (1–30), today first."""
        return self.invoke("band_get_history", {"days": days, "metrics": _metric_list(metrics)})

    def sync(self, days: int = 0) -> dict[str, Any]:
        """Pulls from the band now: 0 = today only."""
        return self.invoke("band_sync", {"days": days})

    def measure(self, type: str, wait: float = 150.0, poll: float = 5.0) -> dict[str, Any]:
        """Spot reading: heart_rate, spo2, blood_pressure, temperature, stress, blood_glucose,
        blood_component, body_composition or ecg. A reading longer than the phone's answer
        (blood pressure ~55 s, ECG up to 2 min) comes back ``still_measuring``; this then
        follows ``band_get_status`` until it ends, up to ``wait`` seconds."""
        result = self.invoke("band_measure", {"type": type}, timeout=max(self.timeout, DEFAULT_TIMEOUT))
        if not result.get("still_measuring"):
            return result
        started = (result.get("measurement") or {}).get("time")
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            time.sleep(min(poll, float(result.get("check_again_in_seconds") or poll)))
            status = self.status()
            last = status.get("last_measurement") or {}
            if (last.get("type") == type and last.get("status") != "measuring"
                    and (started is None or str(last.get("time", "")) >= started)):
                return {"ok": True, "measurement": last}
            if status.get("measuring") != type:
                break
        return result

    def workout(self, action: str, sport: str | None = None) -> dict[str, Any]:
        """start (with ``sport``), pause, resume, end or status of a workout, run on the phone's workout screen."""
        if sport is not None and action != "start":
            raise BandError("sport only goes with action start")
        return self.invoke("band_workout", {"action": action, "sport": sport})

    def find(self, stop: bool = False) -> dict[str, Any]:
        """Makes the band vibrate until it is found (pressed) or times out; ``stop`` stops it."""
        return self.invoke("band_find", {"stop": True} if stop else {})

    def heart_rate_alarm(self, enabled: bool, high: int | None = None, low: int | None = None) -> dict[str, Any]:
        """Vibrate when heart rate goes above ``high`` or below ``low`` (bpm)."""
        args: dict[str, Any] = {"enabled": enabled}
        if high is not None:
            args["high"] = high
        if low is not None:
            args["low"] = low
        return self.invoke("band_set_heart_rate_alarm", args)

    def raise_to_wake(self, enabled: bool) -> dict[str, Any]:
        """Raise-the-wrist wake on or off."""
        return self.invoke("band_set_raise_to_wake", {"enabled": enabled})

    def skin_tone(self, level: int) -> dict[str, Any]:
        """The optical sensor's skin-tone calibration, 1 (lightest) to 6 (darkest)."""
        if not 1 <= level <= 6:
            raise BandError("skin tone level must be 1-6")
        return self.invoke("band_set_skin_tone", {"level": level})

    def camera(self, on: bool) -> dict[str, Any]:
        """Camera-remote mode on or off."""
        return self.invoke("band_camera", {"on": on})

    def clear_data(self, confirm: bool = False) -> dict[str, Any]:
        """Factory-resets the band (its history and settings). Refused without ``confirm``."""
        if not confirm:
            raise BandError("clear-data factory-resets the band; pass --confirm only if the user asked")
        return self.invoke("band_clear_data", {"confirm": True})

    def set_alerts(self, calls: bool | None = None, messages: bool | None = None,
                   apps: str | Iterable[str] | None = None) -> dict[str, Any]:
        """Which alerts vibrate the band: incoming ``calls``, ``messages``, and these ``apps`` (``[]`` = none)."""
        if calls is None and messages is None and apps is None:
            raise BandError("give at least one of calls, messages or apps")
        return self.invoke("band_set_alerts", {
            "calls": None if calls is None else bool(calls),
            "messages": None if messages is None else bool(messages),
            "apps": _names(apps),
        })

    def set_alarm(self, action: str, time: str | None = None, days: str | Iterable[str] | None = None,
                  alarm_id: int | None = None, enabled: bool | None = None) -> dict[str, Any]:
        """``list`` the band's alarms, ``add`` one at ``time`` (repeating on ``days``), or ``delete`` one by id."""
        if action not in ALARM_ACTIONS:
            raise BandError(f"action must be one of {', '.join(ALARM_ACTIONS)}")
        if action == "list" and not (time is None and days is None and alarm_id is None and enabled is None):
            raise BandError("list takes no other arguments")
        if action == "add" and time is None:
            raise BandError("add needs a time (HH:MM)")
        if action == "delete" and (alarm_id is None or time is not None or days is not None or enabled is not None):
            raise BandError("delete takes only the alarm's id (from list)")
        return self.invoke("band_set_alarm", {
            "action": action, "time": _clock(time, "time"), "days": _days(days), "id": alarm_id,
            "enabled": None if enabled is None else bool(enabled),
        })

    def set_sedentary(self, enabled: bool, interval_minutes: int | None = None,
                      start: str | None = None, end: str | None = None) -> dict[str, Any]:
        """The sit-too-long reminder: on or off, how often, and the hours it covers (``HH:MM``)."""
        return self.invoke("band_set_sedentary", {
            "enabled": bool(enabled), "interval_minutes": interval_minutes,
            "start": _clock(start, "start"), "end": _clock(end, "end"),
        })

    def set_profile(self, **profile: Any) -> dict[str, Any]:
        """sex (male/female), age, height_cm, weight_kg; the rest keep their values."""
        unknown = sorted(set(profile) - set(PROFILE_FIELDS))
        if unknown:
            raise BandError(f"unknown profile field(s) {', '.join(unknown)}; use {', '.join(PROFILE_FIELDS)}")
        args = _compact(profile)
        if not args:
            raise BandError(f"give at least one profile field: {', '.join(PROFILE_FIELDS)}")
        return self.invoke("band_set_profile", args)

    def set_monitoring(self, metric: str, enabled: bool, interval_minutes: int | None = None) -> dict[str, Any]:
        """Automatic background measurement for heart_rate, spo2, blood_pressure or temperature."""
        return self.invoke("band_set_monitoring", {"metric": metric, "enabled": bool(enabled),
                                                   "interval_minutes": interval_minutes})

    def log(self, limit: int | None = None) -> dict[str, Any]:
        """The band's recent command log, decoded, newest first."""
        return self.invoke("band_get_log", {"limit": limit})


# ── CLI ──────────────────────────────────────────────────────────────────────

def _metrics_csv(text: str) -> list[str]:
    names = [name.strip() for name in text.split(",") if name.strip()]
    if not names or any(name not in METRICS for name in names):
        raise argparse.ArgumentTypeError("metrics must be a comma-separated list of: " + ", ".join(METRICS))
    return names


def _on_off(text: str) -> bool:
    if text not in ("on", "off"):
        raise argparse.ArgumentTypeError("must be on or off")
    return text == "on"


class _Parser(argparse.ArgumentParser):
    """Usage errors keep the CLI contract: ``{"error": ...}`` on stderr and exit code 1."""

    def error(self, message: str) -> NoReturn:
        print(json.dumps({"error": f"{self.prog}: {message}"}), file=sys.stderr)
        sys.exit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="band.py", description="Read and control the HBand smart band through the paired "
                                                  "phone. Prints JSON.")
    parser.add_argument("--device", help="paired device id or name substring (default: the device offering "
                                         "band_get_status)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="seconds to wait for the phone (default 45)")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    sub.add_parser("status", help="connection, battery, wear and today's summary")

    p = sub.add_parser("day", help="one day's summary; --detail adds series, sleep stages and readings")
    p.add_argument("--date", help="YYYY-MM-DD (default today)")
    p.add_argument("--metrics", type=_metrics_csv, help="comma-separated: " + ",".join(METRICS))
    p.add_argument("--detail", action="store_true")

    p = sub.add_parser("health-day", help="one day in the Jarvis Health wire shape")
    p.add_argument("--date", help="YYYY-MM-DD (default today)")

    p = sub.add_parser("history", help="daily summaries for recent days, today first")
    p.add_argument("--days", type=int, default=7, help="1-30 (default 7)")
    p.add_argument("--metrics", type=_metrics_csv, help="comma-separated: " + ",".join(METRICS))

    p = sub.add_parser("sync", help="pull stored data from the band now")
    p.add_argument("--days", type=int, default=0, help="0 = today only (default 0)")

    p = sub.add_parser("measure", help="take a spot reading now (the band must be worn)")
    p.add_argument("type", choices=MEASUREMENTS)

    p = sub.add_parser("workout", help="start, pause, resume, end or read a workout on the phone's workout screen")
    p.add_argument("action", choices=WORKOUT_ACTIONS)
    p.add_argument("--sport", help="for start: run, walk, cycling, hiking, yoga, ... (default run)")

    p = sub.add_parser("find", help="make the band vibrate until found; --stop stops it")
    p.add_argument("--stop", action="store_true", help="stop the band vibrating")

    p = sub.add_parser("hr-alarm", help="vibrate when heart rate leaves a range")
    p.add_argument("state", choices=("on", "off"))
    p.add_argument("--high", type=int)
    p.add_argument("--low", type=int)
    p = sub.add_parser("raise-to-wake", help="raise-the-wrist wake")
    p.add_argument("state", choices=("on", "off"))
    p = sub.add_parser("skin-tone", help="optical sensor skin-tone calibration")
    p.add_argument("level", type=int)
    p = sub.add_parser("camera", help="camera-remote mode")
    p.add_argument("state", choices=("on", "off"))
    p = sub.add_parser("clear-data", help="FACTORY-RESET the band (erases its history and settings)")
    p.add_argument("--confirm", action="store_true")

    p = sub.add_parser("alerts", help="which calls, messages and apps vibrate the band")
    p.add_argument("--calls", type=_on_off, metavar="on|off")
    p.add_argument("--messages", type=_on_off, metavar="on|off")
    p.add_argument("--apps", help="comma-separated app names; an empty string turns every app alert off")

    p = sub.add_parser("alarm", help="list, add or delete the band's vibrating alarms")
    p.add_argument("action", choices=ALARM_ACTIONS)
    p.add_argument("--time", help="for add: HH:MM, 24-hour")
    p.add_argument("--days", help="for add: comma-separated " + ",".join(DAYS) + " (repeat days)")
    p.add_argument("--id", dest="alarm_id", type=int, help="for delete: the alarm's id from list")
    p.add_argument("--enabled", type=_on_off, metavar="on|off", help="for add: whether the alarm is on")

    p = sub.add_parser("sedentary", help="the sit-too-long reminder")
    p.add_argument("state", choices=("on", "off"))
    p.add_argument("--interval", type=int, help="minutes of sitting before a reminder")
    p.add_argument("--start", help="HH:MM the reminder starts covering")
    p.add_argument("--end", help="HH:MM the reminder stops covering")

    p = sub.add_parser("profile", help="body profile; unspecified fields keep their values")
    p.add_argument("--sex", choices=("male", "female"))
    p.add_argument("--age", type=int)
    p.add_argument("--height-cm", dest="height_cm", type=int)
    p.add_argument("--weight-kg", dest="weight_kg", type=int)

    p = sub.add_parser("monitoring", help="turn automatic background measurement on or off")
    p.add_argument("metric", choices=MONITORED_METRICS)
    p.add_argument("state", choices=("on", "off"))
    p.add_argument("--interval", type=int, help="minutes between readings")

    p = sub.add_parser("log", help="the band's recent command log")
    p.add_argument("--limit", type=int, help="entries, newest first")
    return parser


def _run(band: Band, args: argparse.Namespace) -> dict[str, Any]:
    command = args.command
    if command == "status":
        return band.status()
    if command == "day":
        return band.day(date=args.date, metrics=args.metrics, detail=args.detail)
    if command == "health-day":
        return band.health_day(date=args.date)
    if command == "history":
        return band.history(days=args.days, metrics=args.metrics)
    if command == "sync":
        return band.sync(days=args.days)
    if command == "measure":
        return band.measure(args.type)
    if command == "workout":
        return band.workout(args.action, sport=args.sport)
    if command == "find":
        return band.find(stop=args.stop)
    if command == "hr-alarm":
        return band.heart_rate_alarm(args.state == "on", high=args.high, low=args.low)
    if command == "raise-to-wake":
        return band.raise_to_wake(args.state == "on")
    if command == "skin-tone":
        return band.skin_tone(args.level)
    if command == "camera":
        return band.camera(args.state == "on")
    if command == "clear-data":
        return band.clear_data(confirm=args.confirm)
    if command == "alerts":
        return band.set_alerts(calls=args.calls, messages=args.messages, apps=args.apps)
    if command == "alarm":
        return band.set_alarm(args.action, time=args.time, days=args.days, alarm_id=args.alarm_id,
                              enabled=args.enabled)
    if command == "sedentary":
        return band.set_sedentary(args.state == "on", interval_minutes=args.interval, start=args.start,
                                  end=args.end)
    if command == "profile":
        return band.set_profile(**{name: getattr(args, name) for name in PROFILE_FIELDS})
    if command == "monitoring":
        return band.set_monitoring(args.metric, args.state == "on", interval_minutes=args.interval)
    if command == "log":
        return band.log(limit=args.limit)
    raise BandError(f"unknown command {command!r}")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = _run(Band(device=args.device, timeout=args.timeout), args)
    except BandError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
