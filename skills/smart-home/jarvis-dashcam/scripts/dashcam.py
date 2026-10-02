#!/usr/bin/env python3
"""JarvisCopilot — dashcam SDK and CLI.

Two halves:

- The Jarvis server's clip index (``/api/dashcam``): clips, drives, "where was I / how fast
  at <time>", trip stats, GPX, and upload destinations (Google Drive, SFTP, FTP, SMB).
- The camera itself, through the paired iPhone that holds its Wi-Fi link and advertises the
  ``dashcam_*`` device skills (lock a clip, snapshot, recording, settings, SD card, Wi-Fi,
  pull a time range).

Both go through the devices skill's host-signed webui client, so this runs on the Jarvis
server (or wherever the web UI runs). Stdlib only, Python 3.10+.

CLI (JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure):

    python3 dashcam.py status
    python3 dashcam.py clips --kind event --from 2026-10-01T00:00:00-05:00
    python3 dashcam.py where --at 2026-10-01T15:40:00-05:00
    python3 dashcam.py stats --days 7
    python3 dashcam.py lock
    python3 dashcam.py record off

Python:

    from dashcam import Dashcam, DashcamError
    cam = Dashcam()
    cam.where("2026-10-01T15:40:00-05:00")["speed_mph"]
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import re
import sys
import time
import types
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn
from urllib.parse import quote, urlencode

API = "/api/dashcam"
STATUS_SKILL = "dashcam_get_status"
DEVICE_SKILLS = (
    "dashcam_get_status", "dashcam_sync", "dashcam_lock_clip", "dashcam_snapshot", "dashcam_set_recording",
    "dashcam_get_settings", "dashcam_set_setting", "dashcam_sd_info", "dashcam_format_sd",
    "dashcam_delete_file", "dashcam_set_wifi", "dashcam_fetch_range",
)
# CLI command -> the device skills it runs.
CLI_SKILLS = {
    "camera-status": ("dashcam_get_status",),
    "sync": ("dashcam_sync",),
    "lock": ("dashcam_lock_clip",),
    "snapshot": ("dashcam_snapshot",),
    "record": ("dashcam_set_recording",),
    "settings": ("dashcam_get_settings", "dashcam_set_setting"),
    "sd": ("dashcam_sd_info",),
    "format-sd": ("dashcam_format_sd",),
    "delete-file": ("dashcam_delete_file",),
    "wifi": ("dashcam_set_wifi",),
    "fetch": ("dashcam_fetch_range",),
}
KINDS = ("normal", "event", "parking", "photo")
LENSES = ("front", "rear", "inside")
CLIP_STATES = ("on_camera_only", "on_phone", "uploading", "uploaded", "failed", "pending_upload")
DEST_TYPES = ("drive", "sftp", "ftp", "smb")

MPS_TO_MPH = 2.2369362920544
M_PER_MILE = 1609.344
NEAREST_MAX_S = 120          # a fix further than this from the asked time doesn't answer "where"
CLIP_SEARCH_S = 15 * 60      # "where" looks at every clip starting within this of the asked time
CLIP_PAGE = 500              # the server's largest page
MAX_CLIP_PAGES = 4
MAX_CLIPS_SEARCHED = 400     # only a runaway index gets near this

# The phone answers every skill within 25 s of receiving it; the rest covers waking a
# backgrounded app by push. Pulling a time range can take longer, but the skill only queues it.
DEFAULT_TIMEOUT = 45.0
HTTP_GRACE = 5.0

_HERE = Path(__file__).resolve()
_DEVICES_REL = Path("skills", "jarviscopilot", "devices", "scripts", "devices.py")
_DEVICE_ID = re.compile(r"[0-9a-f]{32}")
_PASTE = re.compile(r"Paste the following into your remote machine --->\s*(.*?)\s*<---End paste", re.DOTALL)
_loaded_devices: dict[Path, types.ModuleType] = {}


class DashcamError(RuntimeError):
    """The call could not be made, or the server, phone or camera refused it."""


# ── devices skill ────────────────────────────────────────────────────────────

def _devices_candidates() -> list[Path]:
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
            raise DashcamError(f"could not load {resolved}: {exc}") from exc
        if not callable(getattr(module, "_http", None)):
            raise DashcamError(f"{resolved} has no _http client; update the devices skill")
        _loaded_devices[resolved] = module
        return module
    raise DashcamError(
        "could not find the devices skill's devices.py (looked in: "
        + ", ".join(str(path) for path in candidates)
        + "). Install the jarviscopilot/devices skill or set JARVISCOPILOT_DIR to the JarvisCopilot checkout."
    )


# ── helpers ──────────────────────────────────────────────────────────────────

def _compact(values: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in values.items() if v is not None}


def _failure(status: int, data: Any) -> str:
    text = ""
    if isinstance(data, dict):
        text = str(data.get("error") or data.get("detail") or "")
    if status < 0:
        return "could not reach the Jarvis web UI" + (f": {text}" if text else "")
    return text or f"HTTP {status}"


def parse_time(text: str, require_offset: bool = False) -> float:
    """Unix seconds from ISO-8601 (``Z`` or an offset; no offset means this machine's local time,
    or an error with ``require_offset`` - the server's clock zone is rarely the driver's)."""
    raw = str(text or "").strip()
    if raw.endswith(("Z", "z")):
        raw = raw[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        raise DashcamError(f"could not read the time {text!r}; use ISO-8601 like 2026-10-01T15:40:00-05:00") from None
    if dt.tzinfo is None:
        if require_offset:
            raise DashcamError(f"the time {text!r} has no UTC offset; add one, like 2026-10-01T15:40:00-05:00 "
                               "(or Z for UTC)")
        dt = dt.astimezone()
    return dt.timestamp()


def utc_iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _to_utc(text: str | None) -> str | None:
    return None if text is None else utc_iso(parse_time(text))


def _mph(mps) -> float | None:
    return None if mps is None else round(float(mps) * MPS_TO_MPH, 1)


def _decorate_drive(drive: dict) -> dict:
    out = dict(drive)
    out["miles"] = round(float(drive.get("distance_m") or 0) / M_PER_MILE, 2)
    out["avg_mph"] = _mph(drive.get("avg_mps") or 0)
    out["max_mph"] = _mph(drive.get("max_mps") or 0)
    out["minutes"] = round(float(drive.get("duration_s") or 0) / 60, 1)
    return out


def extract_drive_token(text: str) -> str:
    """The token JSON from ``rclone authorize drive`` output (or the token JSON itself)."""
    raw = str(text or "")
    m = _PASTE.search(raw)
    blob = (m.group(1) if m else raw).strip()
    candidates = [blob]
    try:
        candidates.append(base64.b64decode(blob + "=" * (-len(blob) % 4), validate=False).decode("utf-8").strip())
    except Exception:
        pass
    for candidate in candidates:
        try:
            parsed = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(parsed, dict) and (parsed.get("access_token") or parsed.get("refresh_token")):
            return candidate
    raise DashcamError("no Drive token found: paste everything `rclone authorize drive` printed between "
                       "'Paste the following' and 'End paste'")


# ── SDK ──────────────────────────────────────────────────────────────────────

class Dashcam:
    """The Jarvis server's dashcam index plus the camera, through the phone holding its Wi-Fi.

    ``device`` picks that phone: a paired device id, an id prefix, or a name substring.
    Omitted, the device offering ``dashcam_get_status`` is found on first use.
    ``transport`` stands in for devices._http: ``(method, path, body, timeout) -> (status, data)``.
    """

    def __init__(self, device: str | None = None, timeout: float = DEFAULT_TIMEOUT,
                 transport: Callable[..., tuple[int, Any]] | None = None) -> None:
        self.device = device.strip() if device and device.strip() else None
        self.timeout = float(timeout)
        self.device_id: str | None = None
        self._transport = transport

    # plumbing

    def _request(self, method: str, path: str, body: dict[str, Any] | None, timeout: float) -> tuple[int, Any]:
        if self._transport is None:
            self._transport = load_devices_module()._http
        return self._transport(method, path, body, timeout)

    def _api(self, method: str, path: str, body: dict[str, Any] | None = None, *,
             params: dict[str, Any] | None = None, allow_not_ok: bool = False) -> Any:
        query = urlencode(_compact(params or {}))
        status, data = self._request(method, API + path + (f"?{query}" if query else ""), body, self.timeout)
        if not 200 <= status < 300 or (not allow_not_ok and isinstance(data, dict) and data.get("ok") is False):
            raise DashcamError(f"{method} {API}{path}: {_failure(status, data)}")
        return data

    def resolve_device(self) -> str:
        if self.device_id is None:
            self.device_id = self._match(self.device) if self.device else self._discover()
        return self.device_id

    def _skill_rows(self) -> list[dict[str, Any]]:
        status, data = self._request("GET", "/api/devices/skills", None, self.timeout)
        if not 200 <= status < 300:
            raise DashcamError("could not list device skills: " + _failure(status, data))
        rows = data.get("skills") if isinstance(data, dict) else None
        return [row for row in rows or [] if isinstance(row, dict) and row.get("device_id")]

    def _discover(self) -> str:
        ids = list(dict.fromkeys(str(r["device_id"]) for r in self._skill_rows() if r.get("name") == STATUS_SKILL))
        if not ids:
            raise DashcamError(f"no online device offers {STATUS_SKILL}: the Jarvis iOS app must be paired and "
                               "reachable, with the dashcam set up in Devices")
        if len(ids) == 1:
            return ids[0]
        status, data = self._request("GET", "/api/devices", None, self.timeout)
        rows = data.get("devices") if 200 <= status < 300 and isinstance(data, dict) else None
        state = {str(r.get("id")): r for r in rows or [] if isinstance(r, dict)}
        return sorted(ids, key=lambda d: (not state.get(d, {}).get("invokable", False),
                                          not state.get(d, {}).get("bridge_connected", False)))[0]

    def _match(self, query: str) -> str:
        lowered = query.lower()
        if _DEVICE_ID.fullmatch(lowered):
            return lowered
        names: dict[str, str] = {}
        has_cam: set[str] = set()
        for row in self._skill_rows():
            device_id = str(row["device_id"])
            names.setdefault(device_id, str(row.get("device_name") or ""))
            if row.get("name") == STATUS_SKILL:
                has_cam.add(device_id)
        matches = [d for d in names if d.lower().startswith(lowered) or lowered in names[d].lower()]
        if not matches:
            online = ", ".join(sorted(set(names.values()))) or "none"
            raise DashcamError(f"no online device matching {query!r} (online: {online})")
        return sorted(matches, key=lambda d: (0 if d.lower() == lowered else 1 if d.lower().startswith(lowered)
                                              else 2, d not in has_cam))[0]

    def invoke(self, skill: str, args: dict[str, Any] | None = None, timeout: float | None = None) -> dict[str, Any]:
        """Runs one ``dashcam_*`` device skill on the phone; returns its result or raises DashcamError."""
        wait = self.timeout if timeout is None else float(timeout)
        body = {"device_id": self.resolve_device(), "skill": skill, "args": _compact(args or {}), "timeout": wait}
        status, data = self._request("POST", "/api/devices/skills/invoke", body, wait + HTTP_GRACE)
        if not 200 <= status < 300 or not isinstance(data, dict) or data.get("ok") is False:
            raise DashcamError(f"{skill}: {_failure(status, data)}")
        result = data.get("result")
        if isinstance(result, dict):
            if result.get("ok") is False:
                raise DashcamError(f"{skill}: {_failure(status, result)}")
            return result
        return {"result": result}

    # server: clips and drives

    def status(self) -> dict[str, Any]:
        """Cameras, sync rules, destinations, clip counts and staging use."""
        return self._api("GET", "/state")

    def clips(self, kind: str | None = None, lens: str | None = None, state: str | None = None,
              start_from: str | None = None, start_to: str | None = None, drive: str | None = None,
              limit: int | None = 20, cursor: str | None = None) -> dict[str, Any]:
        """Clips newest first; ``next`` is the cursor for the following page."""
        return self._api("GET", "/clips", params={
            "kind": kind, "lens": lens, "state": state, "from": _to_utc(start_from), "to": _to_utc(start_to),
            "drive": drive, "limit": limit, "cursor": cursor})

    def clip(self, clip_id: str) -> dict[str, Any]:
        """One clip with its GPS fixes and per-destination upload status."""
        return self._api("GET", f"/clips/{quote(clip_id, safe='')}")

    def retry(self, clip_id: str) -> dict[str, Any]:
        """Re-queues the clip's failed destinations."""
        return self._api("POST", f"/clips/{quote(clip_id, safe='')}/retry", {})

    def drives(self, days: float | None = 7, start_from: str | None = None,
               start_to: str | None = None) -> dict[str, Any]:
        """Drives newest first, with miles and mph added."""
        lo = _to_utc(start_from) if start_from else (utc_iso(time.time() - float(days) * 86400) if days else None)
        data = self._api("GET", "/drives", params={"from": lo, "to": _to_utc(start_to)})
        return {"drives": [_decorate_drive(d) for d in data.get("drives") or []]}

    def drive(self, drive_id: str) -> dict[str, Any]:
        """One drive with its thinned route ``[[lat, lon, speed_mps], ...]`` and clips."""
        data = self._api("GET", f"/drives/{quote(drive_id, safe='')}")
        data["drive"] = _decorate_drive(data.get("drive") or {})
        return data

    def gpx(self, drive_id: str) -> str:
        data = self._api("GET", f"/drives/{quote(drive_id, safe='')}.gpx")
        text = data.get("raw") if isinstance(data, dict) else None
        if not isinstance(text, str):
            raise DashcamError("the server did not return GPX")
        return text

    def stats(self, days: float = 7) -> dict[str, Any]:
        """Totals over the last ``days``: drives, miles, hours, top and average mph."""
        drives = self.drives(days=days)["drives"]
        distance = sum(float(d.get("distance_m") or 0) for d in drives)
        moving = sum(float(d.get("moving_s") or 0) for d in drives)
        return {
            "days": days, "drives": len(drives), "miles": round(distance / M_PER_MILE, 1),
            "hours": round(sum(float(d.get("duration_s") or 0) for d in drives) / 3600, 2),
            "driving_hours": round(moving / 3600, 2),
            "top_mph": _mph(max((float(d.get("max_mps") or 0) for d in drives), default=0.0)),
            "avg_mph": _mph(distance / moving) if moving > 0 else 0.0,
        }

    def fix_at(self, at: str, max_gap_s: float = NEAREST_MAX_S) -> dict[str, Any]:
        """The GPS fix nearest to ``at`` (within ``max_gap_s``; ``at`` needs a UTC offset). Every
        clip of the drives around that time (they hold clips by GPS time, right even when the
        camera's clock is off) and every clip starting within 15 min of it is searched - those
        covering ``at`` first - until a fix within 2 s turns up."""
        t = parse_time(at, require_offset=True)
        candidates: dict[str, dict] = {}
        drives = self._api("GET", "/drives", params={"from": utc_iso(t - max_gap_s), "to": utc_iso(t + max_gap_s)})
        for drive in drives.get("drives") or []:
            detail = self._api("GET", f"/drives/{quote(str(drive.get('id')), safe='')}")
            for clip in detail.get("clips") or []:
                if isinstance(clip, dict) and clip.get("id"):
                    candidates.setdefault(clip["id"], clip)
        cursor = None
        for _ in range(MAX_CLIP_PAGES):
            window = self._api("GET", "/clips", params={"from": utc_iso(t - CLIP_SEARCH_S),
                                                         "to": utc_iso(t + CLIP_SEARCH_S),
                                                         "limit": CLIP_PAGE, "cursor": cursor})
            for clip in window.get("clips") or []:
                if isinstance(clip, dict) and clip.get("id"):
                    candidates.setdefault(clip["id"], clip)
            cursor = window.get("next")
            if not cursor:
                break

        def distance(clip: dict) -> tuple[float, float]:
            """(how far ``at`` is outside the clip's window, how far from its middle)."""
            try:
                start = parse_time(clip["start"])
            except (DashcamError, KeyError, TypeError):
                return float("inf"), float("inf")
            length = float(clip.get("duration_s") or 60)
            return max(0.0, start - t, t - (start + length)), abs(start + length / 2 - t)

        ordered = sorted((c for c in candidates.values() if c.get("has_gps") is not False), key=distance)
        best = None
        for clip in ordered[:MAX_CLIPS_SEARCHED]:
            detail = self._api("GET", f"/clips/{quote(clip['id'], safe='')}")
            for fix in detail.get("fixes") or []:
                if not isinstance(fix, list) or len(fix) != 5:
                    continue
                gap = fix[0] - t
                if best is None or abs(gap) < abs(best[0]):
                    best = (gap, fix, detail.get("clip") or clip)
            if best is not None and abs(best[0]) <= 2:
                break
        if best is None or abs(best[0]) > max_gap_s:
            raise DashcamError(f"no GPS fix within {int(max_gap_s)} s of {utc_iso(t)}")
        gap, (ft, lat, lon, speed, heading), clip = best
        return {"at": utc_iso(t), "fix_time": utc_iso(ft), "offset_s": round(gap, 1), "lat": lat, "lon": lon,
                "speed_mps": speed, "speed_mph": _mph(speed), "heading_deg": heading,
                "clip_id": clip.get("id"), "clip_name": clip.get("name"),
                "map_url": f"https://www.google.com/maps?q={lat:.6f},{lon:.6f}"}

    def where(self, at: str) -> dict[str, Any]:
        """Where the car was at ``at``: lat/lon, mph, heading, the clip, a map link."""
        return self.fix_at(at)

    def speed(self, at: str) -> dict[str, Any]:
        """How fast the car was going at ``at``."""
        fix = self.fix_at(at)
        return {k: fix[k] for k in ("at", "fix_time", "offset_s", "speed_mph", "speed_mps", "heading_deg",
                                    "clip_id", "clip_name")}

    # server: destinations

    def destinations(self) -> dict[str, Any]:
        return self._api("GET", "/destinations")

    def add_destination(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Adds an upload destination; passwords and tokens go to the server's rclone config only."""
        return self._api("POST", "/destinations", _compact(payload))

    def test_destination(self, dest_id: str) -> dict[str, Any]:
        return self._api("POST", f"/destinations/{quote(dest_id, safe='')}/test", {}, allow_not_ok=True)

    def delete_destination(self, dest_id: str) -> dict[str, Any]:
        return self._api("POST", f"/destinations/{quote(dest_id, safe='')}/delete", {})

    # camera (device skills on the phone)

    def camera_status(self) -> dict[str, Any]:
        """On the camera's Wi-Fi or away, recording, SD, last sync, queue."""
        return self.invoke("dashcam_get_status")

    def sync(self, resync: bool = False) -> dict[str, Any]:
        """Syncs now when the phone is on the camera's Wi-Fi; ``resync`` re-checks every clip."""
        return self.invoke("dashcam_sync", {"resync": True if resync else None})

    def lock(self) -> dict[str, Any]:
        """Saves the current moment as a locked event clip."""
        return self.invoke("dashcam_lock_clip")

    def snapshot(self, lens: str | None = None) -> dict[str, Any]:
        """Takes a photo (``front``/``rear``); the phone returns it as a file."""
        return self.invoke("dashcam_snapshot", {"lens": lens})

    def set_recording(self, enabled: bool) -> dict[str, Any]:
        return self.invoke("dashcam_set_recording", {"enabled": bool(enabled)})

    def settings(self) -> dict[str, Any]:
        """The camera's settings with their allowed values."""
        return self.invoke("dashcam_get_settings")

    def set_setting(self, key: str, value: str) -> dict[str, Any]:
        return self.invoke("dashcam_set_setting", {"key": key, "value": value})

    def sd_info(self) -> dict[str, Any]:
        return self.invoke("dashcam_sd_info")

    def format_sd(self, confirm: bool = False) -> dict[str, Any]:
        """Erases the camera's SD card. Needs ``confirm=True``."""
        if confirm is not True:
            raise DashcamError("formatting erases every clip on the camera; pass confirm=True (--confirm)")
        return self.invoke("dashcam_format_sd", {"confirm": True})

    def delete_file(self, path: str, confirm: bool = False) -> dict[str, Any]:
        """Deletes one file on the camera. Needs ``confirm=True``."""
        if confirm is not True:
            raise DashcamError("deleting a camera file can't be undone; pass confirm=True (--confirm)")
        return self.invoke("dashcam_delete_file", {"path": path, "confirm": True})

    def set_wifi(self, ssid: str | None = None, password: str | None = None) -> dict[str, Any]:
        """Renames the camera's Wi-Fi and/or changes its password (the phone re-saves the network)."""
        if ssid is None and password is None:
            raise DashcamError("give ssid and/or password")
        return self.invoke("dashcam_set_wifi", {"ssid": ssid, "password": password})

    def fetch(self, start_from: str, start_to: str) -> dict[str, Any]:
        """Queues every clip covering the time range for pulling and upload."""
        return self.invoke("dashcam_fetch_range", {"from": _to_utc(start_from), "to": _to_utc(start_to)})


# ── CLI ──────────────────────────────────────────────────────────────────────

class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        print(json.dumps({"error": f"{self.prog}: {message}"}), file=sys.stderr)
        sys.exit(1)


def _csv_kinds(text: str) -> list[str]:
    kinds = [k.strip() for k in text.split(",") if k.strip()]
    if not kinds or any(k not in KINDS for k in kinds):
        raise argparse.ArgumentTypeError("kinds must be a comma-separated list of: " + ", ".join(KINDS))
    return kinds


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="dashcam.py", description="Dashcam clips, drives and camera control. Prints JSON.")
    parser.add_argument("--device", help="paired phone id or name substring (default: the one offering "
                                         "dashcam_get_status)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="seconds (default 45)")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    sub.add_parser("status", help="cameras, rules, destinations, clip counts (server)")
    p = sub.add_parser("clips", help="clips newest first")
    p.add_argument("--kind", choices=KINDS)
    p.add_argument("--lens", choices=LENSES)
    p.add_argument("--state", choices=CLIP_STATES)
    p.add_argument("--from", dest="start_from", help="ISO time with offset")
    p.add_argument("--to", dest="start_to", help="ISO time with offset")
    p.add_argument("--drive")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--cursor")
    p = sub.add_parser("clip", help="one clip with fixes and upload status")
    p.add_argument("clip_id")
    p = sub.add_parser("retry", help="re-queue a clip's failed destinations")
    p.add_argument("clip_id")
    p = sub.add_parser("drives", help="recent drives with miles and mph")
    p.add_argument("--days", type=float, default=7)
    p = sub.add_parser("drive", help="one drive with its route")
    p.add_argument("drive_id")
    for name, text in (("where", "where the car was at a time"), ("speed", "how fast the car was going at a time")):
        p = sub.add_parser(name, help=text)
        p.add_argument("--at", required=True, help="ISO time with offset, e.g. 2026-10-01T15:40:00-05:00")
    p = sub.add_parser("stats", help="drive totals")
    p.add_argument("--days", type=float, default=7)
    p = sub.add_parser("gpx", help="a drive as GPX")
    p.add_argument("drive_id")
    p.add_argument("-o", "--output", help="file to write (default: print the GPX)")

    sub.add_parser("destinations", help="upload destinations and their status")
    p = sub.add_parser("add-destination", help="add Google Drive / SFTP / FTP / SMB")
    p.add_argument("--json-stdin", action="store_true", help="read the whole destination JSON from stdin")
    p.add_argument("--type", dest="dtype", choices=DEST_TYPES)
    p.add_argument("--name")
    p.add_argument("--path", default=None, help="folder on the destination (default dashcam)")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--user")
    p.add_argument("--password", help="visible to other local users in ps; prefer --password-stdin")
    p.add_argument("--password-stdin", action="store_true")
    p.add_argument("--token-stdin", action="store_true", help="Drive: `rclone authorize drive` output on stdin")
    p.add_argument("--kinds", type=_csv_kinds, help="comma-separated: " + ",".join(KINDS))
    p = sub.add_parser("test-destination", help="check a destination's login and folder")
    p.add_argument("dest_id")
    p = sub.add_parser("delete-destination", help="remove a destination")
    p.add_argument("dest_id")
    p = sub.add_parser("drive-payload", help="turn `rclone authorize drive` output (stdin) into destination JSON")
    p.add_argument("--name", default="Google Drive")
    p.add_argument("--path", default="dashcam")
    p.add_argument("--client-id", dest="client_id")

    sub.add_parser("camera-status", help="camera link, recording, SD, last sync (phone)")
    p = sub.add_parser("sync", help="sync now while on the camera's Wi-Fi (phone)")
    p.add_argument("--resync", action="store_true", help="re-check every clip")
    sub.add_parser("lock", help="save this moment as a locked clip (phone)")
    p = sub.add_parser("snapshot", help="take a photo (phone)")
    p.add_argument("--lens", choices=("front", "rear"))
    p = sub.add_parser("record", help="turn recording on or off (phone)")
    p.add_argument("state", choices=("on", "off"))
    p = sub.add_parser("settings", help="read or change camera settings (phone)")
    p.add_argument("action", nargs="?", choices=("get", "set"), default="get")
    p.add_argument("key", nargs="?")
    p.add_argument("value", nargs="?")
    sub.add_parser("sd", help="SD card capacity and free space (phone)")
    p = sub.add_parser("format-sd", help="erase the camera's SD card (phone)")
    p.add_argument("--confirm", action="store_true")
    p = sub.add_parser("delete-file", help="delete one file on the camera (phone)")
    p.add_argument("path")
    p.add_argument("--confirm", action="store_true")
    p = sub.add_parser("wifi", help="rename the camera's Wi-Fi or change its password (phone)")
    p.add_argument("--ssid")
    p.add_argument("--password-stdin", action="store_true")
    p = sub.add_parser("fetch", help="pull and upload every clip in a time range (phone)")
    p.add_argument("--from", dest="start_from", required=True)
    p.add_argument("--to", dest="start_to", required=True)
    return parser


def _stdin_line() -> str:
    return sys.stdin.readline().rstrip("\r\n")


def _run(cam: Dashcam, args: argparse.Namespace) -> Any:
    c = args.command
    if c == "status":
        return cam.status()
    if c == "clips":
        return cam.clips(kind=args.kind, lens=args.lens, state=args.state, start_from=args.start_from,
                         start_to=args.start_to, drive=args.drive, limit=args.limit, cursor=args.cursor)
    if c == "clip":
        return cam.clip(args.clip_id)
    if c == "retry":
        return cam.retry(args.clip_id)
    if c == "drives":
        return cam.drives(days=args.days)
    if c == "drive":
        return cam.drive(args.drive_id)
    if c == "where":
        return cam.where(args.at)
    if c == "speed":
        return cam.speed(args.at)
    if c == "stats":
        return cam.stats(days=args.days)
    if c == "gpx":
        text = cam.gpx(args.drive_id)
        if not args.output:
            return text
        try:
            Path(args.output).write_text(text, encoding="utf-8")
        except OSError as exc:
            raise DashcamError(f"could not write {args.output}: {exc.strerror or exc}") from None
        return {"ok": True, "path": args.output}
    if c == "destinations":
        return cam.destinations()
    if c == "add-destination":
        if args.json_stdin:
            try:
                payload = json.loads(sys.stdin.read())
            except ValueError:
                raise DashcamError("stdin is not a JSON object") from None
            if not isinstance(payload, dict):
                raise DashcamError("stdin is not a JSON object")
            return cam.add_destination(payload)
        if not args.dtype or not args.name:
            raise DashcamError("--type and --name are required (or --json-stdin)")
        password = _stdin_line() if args.password_stdin else args.password
        token = extract_drive_token(sys.stdin.read()) if args.token_stdin else None
        return cam.add_destination({"type": args.dtype, "name": args.name, "path": args.path, "host": args.host,
                                    "port": args.port, "user": args.user, "password": password, "token": token,
                                    "kinds": args.kinds})
    if c == "test-destination":
        return cam.test_destination(args.dest_id)
    if c == "delete-destination":
        return cam.delete_destination(args.dest_id)
    if c == "drive-payload":
        return _compact({"type": "drive", "name": args.name, "path": args.path,
                         "token": extract_drive_token(sys.stdin.read()), "client_id": args.client_id,
                         "client_secret": os.environ.get("DASHCAM_DRIVE_CLIENT_SECRET") or None})
    if c == "camera-status":
        return cam.camera_status()
    if c == "sync":
        return cam.sync(resync=args.resync)
    if c == "lock":
        return cam.lock()
    if c == "snapshot":
        return cam.snapshot(lens=args.lens)
    if c == "record":
        return cam.set_recording(args.state == "on")
    if c == "settings":
        if args.action == "set":
            if not args.key or args.value is None:
                raise DashcamError("usage: settings set <key> <value>")
            return cam.set_setting(args.key, args.value)
        return cam.settings()
    if c == "sd":
        return cam.sd_info()
    if c == "format-sd":
        return cam.format_sd(confirm=args.confirm)
    if c == "delete-file":
        return cam.delete_file(args.path, confirm=args.confirm)
    if c == "wifi":
        return cam.set_wifi(ssid=args.ssid, password=_stdin_line() if args.password_stdin else None)
    if c == "fetch":
        return cam.fetch(args.start_from, args.start_to)
    raise DashcamError(f"unknown command {c!r}")


def main(argv: list[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:
        return int(exc.code or 0)
    try:
        result = _run(Dashcam(device=args.device, timeout=args.timeout), args)
    except DashcamError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    if isinstance(result, str):
        print(result)
    else:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
