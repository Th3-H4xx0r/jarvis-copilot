#!/usr/bin/env python3
"""JarvisCopilot — smart ring SDK and CLI (Colmi R12 and other QRing R-series rings).

The Jarvis iOS app holds the ring's Bluetooth link and advertises its commands as
``ring_*`` device skills over the device bridge. This module wraps the devices skill's
host-signed webui client so scripts, cron jobs and automations get one typed call per
skill and plain JSON back. Stdlib only, Python 3.10+.

CLI (JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure):

    python3 ring.py status
    python3 ring.py day --metrics sleep,heart_rate --detail
    python3 ring.py measure heart_rate
    python3 ring.py monitoring heart_rate on --interval 10
    python3 ring.py --device iphone history --days 14

Python:

    from ring import Ring, RingError
    ring = Ring()                      # finds the device offering ring_get_status
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

STATUS_SKILL = "ring_get_status"

# Mirrors the ColmiR12 skill catalogue in ios_app/JarvisCopilot/Ring/ColmiR12.swift.
METRICS = ("activity", "sleep", "heart_rate", "spo2", "hrv", "stress", "temperature",
           "blood_pressure", "blood_sugar")
MEASUREMENTS = ("heart_rate", "spo2", "hrv", "stress", "temperature", "blood_pressure",
                "blood_sugar", "health_check")
MONITORED_METRICS = ("heart_rate", "spo2", "hrv", "stress", "temperature")
TOUCH_MODES = ("off", "music", "video", "page_turn", "photo", "game", "heart_rate")
POWER_ACTIONS = ("power_off", "factory_reset")
GOAL_FIELDS = ("steps", "calories", "distance_m", "sport_minutes", "sleep_minutes")
PROFILE_FIELDS = ("sex", "age", "height_cm", "weight_kg", "use_24h", "metric_units")
PREFERENCE_FIELDS = ("temperature_unit", "dnd", "sedentary")

MEASURE_MAX_WAIT = 25
# The phone answers every skill within 25 s of receiving it; the rest covers waking a
# backgrounded app by push before that clock starts.
DEFAULT_TIMEOUT = 45.0
# The HTTP request outlives the invoke so the server's own timeout error comes back.
HTTP_GRACE = 5.0

_HERE = Path(__file__).resolve()
_DEVICES_REL = Path("skills", "jarviscopilot", "devices", "scripts", "devices.py")
_DEVICE_ID = re.compile(r"[0-9a-f]{32}")  # pairing ids are uuid4().hex
_loaded_devices: dict[Path, types.ModuleType] = {}


class RingError(RuntimeError):
    """The ring call could not be made, or the server, phone or ring refused it."""


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
            raise RingError(f"could not load {resolved}: {exc}") from exc
        if not callable(getattr(module, "_http", None)):
            raise RingError(f"{resolved} has no _http client; update the devices skill")
        _loaded_devices[resolved] = module
        return module
    raise RingError(
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


def _fields(kind: str, given: dict[str, Any], allowed: tuple[str, ...]) -> dict[str, Any]:
    """Keyword arguments for a settings skill: known names only, at least one set."""
    unknown = sorted(set(given) - set(allowed))
    if unknown:
        raise RingError(f"unknown {kind} field(s) {', '.join(unknown)}; use {', '.join(allowed)}")
    args = _compact(given)
    if not args:
        raise RingError(f"give at least one {kind} field: {', '.join(allowed)}")
    return args


def _failure(status: int, data: Any) -> str:
    """The most useful error text from a failed webui reply."""
    text = ""
    if isinstance(data, dict):
        text = str(data.get("error") or data.get("detail") or "")
    if status < 0:
        return "could not reach the Jarvis web UI" + (f": {text}" if text else "")
    return text or f"HTTP {status}"


# ── SDK ──────────────────────────────────────────────────────────────────────

class Ring:
    """A smart ring, reached through the paired phone that advertises its ``ring_*`` skills.

    ``device`` picks that phone: a paired device id, an id prefix, or a case-insensitive
    name substring. Omitted, the device offering ``ring_get_status`` is found on first use.
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
            raise RingError("could not list device skills: " + _failure(status, data))
        rows = data.get("skills") if isinstance(data, dict) else None
        return [row for row in rows or [] if isinstance(row, dict) and row.get("device_id")]

    def _discover(self) -> str:
        ids = list(dict.fromkeys(
            str(row["device_id"]) for row in self._skill_rows() if row.get("name") == STATUS_SKILL))
        if not ids:
            raise RingError(
                f"no online device offers {STATUS_SKILL}: the Jarvis iOS app must be paired and reachable, "
                "and the ring connected once in the app with Share with Jarvis on")
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
        has_ring: set[str] = set()
        for row in self._skill_rows():
            device_id = str(row["device_id"])
            names.setdefault(device_id, str(row.get("device_name") or ""))
            if row.get("name") == STATUS_SKILL:
                has_ring.add(device_id)
        matches = [d for d in names if d.lower().startswith(lowered) or lowered in names[d].lower()]
        if not matches:
            online = ", ".join(sorted(set(names.values()))) or "none"
            raise RingError(f"no online device matching {query!r} (online: {online})")

        def rank(device_id: str) -> tuple[int, bool]:
            how = 0 if device_id.lower() == lowered else 1 if device_id.lower().startswith(lowered) else 2
            return (how, device_id not in has_ring)

        return sorted(matches, key=rank)[0]

    def invoke(self, skill: str, args: dict[str, Any] | None = None,
               timeout: float | None = None) -> dict[str, Any]:
        """Runs one ``ring_*`` skill; returns its result payload or raises RingError."""
        wait = self.timeout if timeout is None else float(timeout)
        body = {"device_id": self.resolve_device(), "skill": skill, "args": _compact(args or {}), "timeout": wait}
        status, data = self._request("POST", "/api/devices/skills/invoke", body, wait + HTTP_GRACE)
        if not 200 <= status < 300 or not isinstance(data, dict) or data.get("ok") is False:
            raise RingError(f"{skill}: {_failure(status, data)}")
        result = data.get("result")
        if isinstance(result, dict):
            if result.get("ok") is False:
                raise RingError(f"{skill}: {_failure(status, result)}")
            return result
        return {"result": result}

    # skills

    def status(self) -> dict[str, Any]:
        """Connection, battery, capabilities, settings, last sync and measurement, today's summary."""
        return self.invoke("ring_get_status")

    def day(self, date: str | None = None, metrics: str | Iterable[str] | None = None,
            detail: bool = False) -> dict[str, Any]:
        """One day (``YYYY-MM-DD``, default today); ``detail`` adds series, sleep stages and step slots."""
        return self.invoke("ring_get_day", {"date": date, "metrics": _metric_list(metrics),
                                            "detail": True if detail else None})

    def history(self, days: int = 7, metrics: str | Iterable[str] | None = None) -> dict[str, Any]:
        """Per-day summaries for the last ``days`` days (1–30), today first."""
        return self.invoke("ring_get_history", {"days": days, "metrics": _metric_list(metrics)})

    def sync(self, days: int = 0) -> dict[str, Any]:
        """Pulls from the ring now: 0 = today only, up to 6."""
        return self.invoke("ring_sync", {"days": days})

    def measure(self, metric: str, wait_seconds: float | None = MEASURE_MAX_WAIT) -> dict[str, Any]:
        """On-demand reading; returns the result, ``status: not_worn`` or ``status: measuring``."""
        wait = MEASURE_MAX_WAIT if wait_seconds is None else int(wait_seconds)
        wait = max(0, min(MEASURE_MAX_WAIT, wait))
        return self.invoke("ring_measure", {"metric": metric, "wait_seconds": wait},
                           timeout=max(self.timeout, DEFAULT_TIMEOUT))

    def find(self) -> dict[str, Any]:
        """Makes the ring vibrate or flash."""
        return self.invoke("ring_find")

    def set_monitoring(self, metric: str, enabled: bool, interval_minutes: int | None = None) -> dict[str, Any]:
        """Automatic background measurement for heart_rate, spo2, hrv, stress or temperature."""
        return self.invoke("ring_set_monitoring", {"metric": metric, "enabled": bool(enabled),
                                                   "interval_minutes": interval_minutes})

    def set_touch_mode(self, control: str, mode: str, strength: int | None = None) -> dict[str, Any]:
        """What a touch or a gesture on the ring controls (``control`` is touch or gesture)."""
        return self.invoke("ring_set_touch_mode", {"control": control, "mode": mode, "strength": strength})

    def set_goals(self, **goals: Any) -> dict[str, Any]:
        """steps, calories (kcal), distance_m, sport_minutes, sleep_minutes; the rest keep their values."""
        return self.invoke("ring_set_goals", _fields("goal", goals, GOAL_FIELDS))

    def set_profile(self, **profile: Any) -> dict[str, Any]:
        """sex (male/female), age, height_cm, weight_kg, use_24h, metric_units; the rest keep their values."""
        return self.invoke("ring_set_profile", _fields("profile", profile, PROFILE_FIELDS))

    def set_preferences(self, **prefs: Any) -> dict[str, Any]:
        """temperature_unit, dnd {enabled, start, end}, sedentary {enabled, start, end, interval_minutes}."""
        return self.invoke("ring_set_preferences", _fields("preference", prefs, PREFERENCE_FIELDS))

    def power(self, action: str, confirm: bool = False) -> dict[str, Any]:
        """power_off or factory_reset. Refuses unless ``confirm`` is True."""
        if confirm is not True:
            consequence = ("a factory reset erases the ring's data and settings" if action == "factory_reset"
                           else "the ring stays off until it is put on its charger")
            raise RingError(f"ring_power needs confirm=True: {consequence}")
        return self.invoke("ring_power", {"action": action, "confirm": True})

    def raw(self, hex: str | None = None, big_data_cmd: int | None = None, payload_hex: str | None = None,
            confirm: bool = False) -> dict[str, Any]:
        """Protocol work: a command frame (``hex``) or a large-data request. Refuses unless ``confirm`` is True."""
        if confirm is not True:
            raise RingError("ring_raw_command needs confirm=True: raw commands can change the ring's state")
        if (hex is None) == (big_data_cmd is None):
            raise RingError("give either hex (opcode + payload) or big_data_cmd with optional payload_hex")
        return self.invoke("ring_raw_command", {"hex": hex, "big_data_cmd": big_data_cmd,
                                                "payload_hex": payload_hex, "confirm": True})

    def firmware_update(self, image_path: str | None = None, url: str | None = None,
                        confirm: bool = False) -> dict[str, Any]:
        """Flash a firmware image to the ring over its own BLE updater. Refuses unless ``confirm``.

        Give ``image_path`` (a local ``.bin``, sent as base64) or ``url`` (the phone downloads it).
        The ring stages the image and commits only after its own magic/model/length checks, so a
        failed transfer leaves the running firmware intact; it reboots into the new image when done.
        The transfer takes minutes and runs in the background on the phone — the reply says
        ``started``; follow progress with ``ring_get_log``.
        """
        if confirm is not True:
            raise RingError("ring_firmware_update needs confirm=True: this reflashes the ring")
        if (image_path is None) == (url is None):
            raise RingError("give either image_path (a local .bin) or url")
        body: dict[str, Any] = {"confirm": True}
        if image_path is not None:
            import base64
            body["image_b64"] = base64.b64encode(Path(image_path).read_bytes()).decode("ascii")
        else:
            body["url"] = url
        return self.invoke("ring_firmware_update", body)


# ── CLI ──────────────────────────────────────────────────────────────────────

def _hhmm(text: str) -> str:
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", text.strip())
    if not match or int(match[1]) > 23 or int(match[2]) > 59:
        raise argparse.ArgumentTypeError(f"{text!r} is not a 24-hour HH:MM time")
    return f"{int(match[1]):02d}:{match[2]}"


def _metrics_csv(text: str) -> list[str]:
    names = [name.strip() for name in text.split(",") if name.strip()]
    if not names or any(name not in METRICS for name in names):
        raise argparse.ArgumentTypeError("metrics must be a comma-separated list of: " + ", ".join(METRICS))
    return names


def _byte(text: str) -> int:
    try:
        value = int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a number (use 39 or 0x27)") from None
    if not 0 <= value <= 255:
        raise argparse.ArgumentTypeError("the large-data opcode must be 0-255")
    return value


class _Parser(argparse.ArgumentParser):
    """Usage errors keep the CLI contract: ``{"error": ...}`` on stderr and exit code 1."""

    def error(self, message: str) -> NoReturn:
        print(json.dumps({"error": f"{self.prog}: {message}"}), file=sys.stderr)
        sys.exit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(
        prog="ring.py",
        description="Read and control the Jarvis smart ring (Colmi R12) through the paired phone. Prints JSON.")
    parser.add_argument("--device", help="paired device id or name substring (default: the device offering "
                                         "ring_get_status)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="seconds to wait for the phone (default 45)")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    sub.add_parser("status", help="connection, battery, capabilities, settings and today's summary")

    p = sub.add_parser("day", help="one day's summary; --detail adds series, sleep stages and step slots")
    p.add_argument("--date", help="YYYY-MM-DD (default today)")
    p.add_argument("--metrics", type=_metrics_csv, help="comma-separated: " + ",".join(METRICS))
    p.add_argument("--detail", action="store_true")

    p = sub.add_parser("history", help="daily summaries for recent days, today first")
    p.add_argument("--days", type=int, default=7, help="1-30 (default 7)")
    p.add_argument("--metrics", type=_metrics_csv, help="comma-separated: " + ",".join(METRICS))

    p = sub.add_parser("sync", help="pull stored data from the ring now")
    p.add_argument("--days", type=int, default=0, help="0 = today only, up to 6 (default 0)")

    p = sub.add_parser("measure", help="take a reading now (the ring must be worn)")
    p.add_argument("metric", choices=MEASUREMENTS)
    p.add_argument("--wait", type=int, default=MEASURE_MAX_WAIT,
                   help="seconds to wait for the result, 0-25 (default 25)")

    sub.add_parser("find", help="make the ring vibrate or flash")

    p = sub.add_parser("monitoring", help="turn automatic background measurement on or off")
    p.add_argument("metric", choices=MONITORED_METRICS)
    p.add_argument("state", choices=("on", "off"))
    p.add_argument("--interval", type=int, help="minutes: heart_rate 1-60, hrv 10-60, temperature 10/30/60/120")

    p = sub.add_parser("touch", help="what a touch or a gesture on the ring controls")
    p.add_argument("control", choices=("touch", "gesture"))
    p.add_argument("mode", choices=TOUCH_MODES)
    p.add_argument("--strength", type=int, help="gesture sensitivity 0-10")

    p = sub.add_parser("goals", help="daily goals; unspecified goals keep their values")
    p.add_argument("--steps", type=int)
    p.add_argument("--calories", type=int, help="kcal")
    p.add_argument("--distance-m", dest="distance_m", type=int)
    p.add_argument("--sport-minutes", dest="sport_minutes", type=int)
    p.add_argument("--sleep-minutes", dest="sleep_minutes", type=int)

    p = sub.add_parser("profile", help="body profile and units; unspecified fields keep their values")
    p.add_argument("--sex", choices=("male", "female"))
    p.add_argument("--age", type=int)
    p.add_argument("--height-cm", dest="height_cm", type=int)
    p.add_argument("--weight-kg", dest="weight_kg", type=int)
    clock = p.add_mutually_exclusive_group()
    clock.add_argument("--24h", dest="use_24h", action="store_const", const=True, help="24-hour clock")
    clock.add_argument("--12h", dest="use_24h", action="store_const", const=False, help="12-hour clock")
    units = p.add_mutually_exclusive_group()
    units.add_argument("--metric", dest="metric_units", action="store_const", const=True)
    units.add_argument("--imperial", dest="metric_units", action="store_const", const=False)

    p = sub.add_parser("prefs", help="temperature unit, do-not-disturb window, sedentary reminder")
    p.add_argument("--temperature-unit", dest="temperature_unit", choices=("celsius", "fahrenheit"))
    dnd = p.add_mutually_exclusive_group()
    dnd.add_argument("--dnd-on", dest="dnd_enabled", action="store_const", const=True)
    dnd.add_argument("--dnd-off", dest="dnd_enabled", action="store_const", const=False)
    p.add_argument("--dnd-start", type=_hhmm, metavar="HH:MM")
    p.add_argument("--dnd-end", type=_hhmm, metavar="HH:MM")
    sedentary = p.add_mutually_exclusive_group()
    sedentary.add_argument("--sedentary-on", dest="sedentary_enabled", action="store_const", const=True)
    sedentary.add_argument("--sedentary-off", dest="sedentary_enabled", action="store_const", const=False)
    p.add_argument("--sedentary-start", type=_hhmm, metavar="HH:MM")
    p.add_argument("--sedentary-end", type=_hhmm, metavar="HH:MM")
    p.add_argument("--sedentary-interval", type=int, choices=(30, 60, 90), help="minutes")

    p = sub.add_parser("power", help="power the ring off or factory-reset it (needs --confirm)")
    p.add_argument("action", choices=POWER_ACTIONS)
    p.add_argument("--confirm", action="store_true")

    p = sub.add_parser("raw", help="protocol work: send raw bytes and print the replies (needs --confirm)")
    p.add_argument("--hex", help="command frame as hex, opcode + payload (checksum added)")
    p.add_argument("--big-data-cmd", dest="big_data_cmd", type=_byte, help="large-data opcode, e.g. 0x27")
    p.add_argument("--payload-hex", dest="payload_hex", help="large-data payload as hex")
    p.add_argument("--confirm", action="store_true")

    p = sub.add_parser("firmware-update",
                       help="flash a firmware .bin over the ring's own BLE updater (needs --confirm)")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--file", dest="fw_file", help="local .bin to send (base64)")
    src.add_argument("--url", dest="fw_url", help="HTTPS URL the phone downloads the .bin from")
    p.add_argument("--confirm", action="store_true")
    return parser


def _run(ring: Ring, args: argparse.Namespace) -> dict[str, Any]:
    command = args.command
    if command == "status":
        return ring.status()
    if command == "day":
        return ring.day(date=args.date, metrics=args.metrics, detail=args.detail)
    if command == "history":
        return ring.history(days=args.days, metrics=args.metrics)
    if command == "sync":
        return ring.sync(days=args.days)
    if command == "measure":
        return ring.measure(args.metric, wait_seconds=args.wait)
    if command == "find":
        return ring.find()
    if command == "monitoring":
        return ring.set_monitoring(args.metric, args.state == "on", interval_minutes=args.interval)
    if command == "touch":
        return ring.set_touch_mode(args.control, args.mode, strength=args.strength)
    if command == "goals":
        return ring.set_goals(**{name: getattr(args, name) for name in GOAL_FIELDS})
    if command == "profile":
        return ring.set_profile(**{name: getattr(args, name) for name in PROFILE_FIELDS})
    if command == "prefs":
        return ring.set_preferences(
            temperature_unit=args.temperature_unit,
            dnd={"enabled": args.dnd_enabled, "start": args.dnd_start, "end": args.dnd_end},
            sedentary={"enabled": args.sedentary_enabled, "start": args.sedentary_start,
                       "end": args.sedentary_end, "interval_minutes": args.sedentary_interval},
        )
    if command == "power":
        return ring.power(args.action, confirm=args.confirm)
    if command == "raw":
        return ring.raw(hex=args.hex, big_data_cmd=args.big_data_cmd, payload_hex=args.payload_hex,
                        confirm=args.confirm)
    if command == "firmware-update":
        return ring.firmware_update(image_path=args.fw_file, url=args.fw_url, confirm=args.confirm)
    raise RingError(f"unknown command {command!r}")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = _run(Ring(device=args.device, timeout=args.timeout), args)
    except RingError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
