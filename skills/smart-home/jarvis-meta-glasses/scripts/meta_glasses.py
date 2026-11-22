#!/usr/bin/env python3
"""JarvisCopilot — Ray-Ban Meta (Gen 2) glasses SDK and CLI.

The Jarvis iOS app holds the glasses' link and advertises their commands as
``meta_glasses_*`` device skills over the device bridge — the same skills whether the
real glasses or the app's hardware simulator is selected. This module wraps the devices
skill's host-signed webui client so scripts, cron jobs and automations get one typed call
per skill and plain JSON back. Stdlib only, Python 3.10+.

CLI (JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure):

    python3 meta_glasses.py status
    python3 meta_glasses.py photo --question "What am I looking at?"
    python3 meta_glasses.py video --seconds 30
    python3 meta_glasses.py live start
    python3 meta_glasses.py speak "Your meeting starts in five minutes"
    python3 meta_glasses.py media latest-photo
    python3 meta_glasses.py settings --clip-length 60 --video-mode 1080p60

Python:

    from meta_glasses import MetaGlasses, MetaGlassesError
    glasses = MetaGlasses()            # finds the device offering meta_glasses_status
    print(glasses.status()["battery_percent"])
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import types
from collections.abc import Callable
from pathlib import Path
from typing import Any

STATUS_SKILL = "meta_glasses_status"
SKILLS = ("meta_glasses_status", "meta_glasses_look", "meta_glasses_photo", "meta_glasses_video",
          "meta_glasses_live", "meta_glasses_speak", "meta_glasses_volume", "meta_glasses_talk",
          "meta_glasses_media", "meta_glasses_settings")
CLIP_LENGTHS = (30, 60, 180)
VIDEO_MODES = ("3k30", "1080p30", "1080p60", "720p120")
MEDIA_ACTIONS = ("list", "latest_photo", "import")

# The phone answers every skill within 25 s of receiving it; the rest covers waking a
# backgrounded app by push before that clock starts.
DEFAULT_TIMEOUT = 45.0
# The HTTP request outlives the invoke so the server's own timeout error comes back.
HTTP_GRACE = 5.0

_HERE = Path(__file__).resolve()
_DEVICES_REL = Path("skills", "jarviscopilot", "devices", "scripts", "devices.py")
_DEVICE_ID = re.compile(r"[0-9a-f]{32}")  # pairing ids are uuid4().hex
_loaded_devices: dict[Path, types.ModuleType] = {}


class MetaGlassesError(RuntimeError):
    """The glasses call could not be made, or the server, phone or glasses refused it."""


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
            raise MetaGlassesError(f"could not load {resolved}: {exc}") from exc
        if not callable(getattr(module, "_http", None)):
            raise MetaGlassesError(f"{resolved} has no _http client; update the devices skill")
        _loaded_devices[resolved] = module
        return module
    raise MetaGlassesError(
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


def _failure(status: int, data: Any) -> str:
    """The most useful error text from a failed webui reply."""
    text = ""
    if isinstance(data, dict):
        text = str(data.get("error") or data.get("detail") or "")
    if status < 0:
        return "could not reach the Jarvis web UI" + (f": {text}" if text else "")
    return text or f"HTTP {status}"


# ── SDK ──────────────────────────────────────────────────────────────────────

class MetaGlasses:
    """The Ray-Ban Meta glasses, reached through the paired phone that advertises their ``meta_glasses_*`` skills.

    ``device`` picks that phone: a paired device id, an id prefix, or a case-insensitive
    name substring. Omitted, the device offering ``meta_glasses_status`` is found on first use.
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
            raise MetaGlassesError("could not list device skills: " + _failure(status, data))
        rows = data.get("skills") if isinstance(data, dict) else None
        return [row for row in rows or [] if isinstance(row, dict) and row.get("device_id")]

    def _discover(self) -> str:
        ids = list(dict.fromkeys(
            str(row["device_id"]) for row in self._skill_rows() if row.get("name") == STATUS_SKILL))
        if not ids:
            raise MetaGlassesError(
                f"no online device offers {STATUS_SKILL}: the Jarvis iOS app must be paired and reachable, "
                "and the Meta glasses (real or the simulator) on in the app")
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
        has_glasses: set[str] = set()
        for row in self._skill_rows():
            device_id = str(row["device_id"])
            names.setdefault(device_id, str(row.get("device_name") or ""))
            if row.get("name") == STATUS_SKILL:
                has_glasses.add(device_id)
        matches = [d for d in names if d.lower().startswith(lowered) or lowered in names[d].lower()]
        if not matches:
            online = ", ".join(sorted(set(names.values()))) or "none"
            raise MetaGlassesError(f"no online device matching {query!r} (online: {online})")

        def rank(device_id: str) -> tuple[int, bool]:
            how = 0 if device_id.lower() == lowered else 1 if device_id.lower().startswith(lowered) else 2
            return (how, device_id not in has_glasses)

        return sorted(matches, key=rank)[0]

    def invoke(self, skill: str, args: dict[str, Any] | None = None,
               timeout: float | None = None) -> dict[str, Any]:
        """Runs one ``meta_glasses_*`` skill; returns its result payload or raises MetaGlassesError."""
        wait = self.timeout if timeout is None else float(timeout)
        body = {"device_id": self.resolve_device(), "skill": skill, "args": _compact(args or {}), "timeout": wait}
        status, data = self._request("POST", "/api/devices/skills/invoke", body, wait + HTTP_GRACE)
        if not 200 <= status < 300 or not isinstance(data, dict) or data.get("ok") is False:
            raise MetaGlassesError(f"{skill}: {_failure(status, data)}")
        result = data.get("result")
        if isinstance(result, dict):
            if result.get("ok") is False:
                raise MetaGlassesError(f"{skill}: {_failure(status, result)}")
            return result
        return {"result": result}

    # skills

    def status(self) -> dict[str, Any]:
        """Battery, charging, worn/folded/in case, heat, storage, recording/streaming, volume, settings."""
        return self.invoke("meta_glasses_status")

    def look(self) -> dict[str, Any]:
        """What the camera can do now (and why not); the current frame while live streaming."""
        return self.invoke("meta_glasses_look")

    def photo(self, question: str | None = None) -> dict[str, Any]:
        """A photo from the glasses camera for vision. Confirms the shutter (the capture LED lights)."""
        return self.invoke("meta_glasses_photo", {"question": question, "confirm": True})

    def video(self, seconds: int | None = None) -> dict[str, Any]:
        """A clip of up to ``seconds`` (capped by the glasses' clip length, 180 s max)."""
        if seconds is not None and not 1 <= int(seconds) <= 180:
            raise MetaGlassesError("seconds must be 1-180")
        wait = max(self.timeout, float(seconds or 30) + 30)
        return self.invoke("meta_glasses_video", {"seconds": seconds, "confirm": True}, timeout=wait)

    def live(self, action: str) -> dict[str, Any]:
        """Start or stop the live stream to the phone."""
        if action not in ("start", "stop"):
            raise MetaGlassesError("action must be start or stop")
        return self.invoke("meta_glasses_live", {"action": action})

    def speak(self, text: str) -> dict[str, Any]:
        """Say text through the glasses' open-ear speakers."""
        if not text.strip():
            raise MetaGlassesError("text is required")
        return self.invoke("meta_glasses_speak", {"text": text})

    def volume(self, level: int) -> dict[str, Any]:
        """Speaker volume 0-100."""
        if not 0 <= int(level) <= 100:
            raise MetaGlassesError("level must be 0-100")
        return self.invoke("meta_glasses_volume", {"level": int(level)})

    def talk(self) -> dict[str, Any]:
        """Open the glasses' assistant so the wearer can ask something."""
        return self.invoke("meta_glasses_talk")

    def media(self, action: str, question: str | None = None) -> dict[str, Any]:
        """list | latest_photo (an image for vision) | import (to the phone's Photos)."""
        if action not in MEDIA_ACTIONS:
            raise MetaGlassesError(f"action must be one of {', '.join(MEDIA_ACTIONS)}")
        return self.invoke("meta_glasses_media", {"action": action, "question": question})

    def settings(self, clip_length_seconds: int | None = None, video_mode: str | None = None) -> dict[str, Any]:
        """Read, or change, the clip length (30/60/180 s) and video mode."""
        if clip_length_seconds is not None and int(clip_length_seconds) not in CLIP_LENGTHS:
            raise MetaGlassesError(f"clip length must be one of {CLIP_LENGTHS}")
        if video_mode is not None and video_mode not in VIDEO_MODES:
            raise MetaGlassesError(f"video mode must be one of {', '.join(VIDEO_MODES)}")
        return self.invoke("meta_glasses_settings", {"clip_length_seconds": clip_length_seconds,
                                                     "video_mode": video_mode})


# ── CLI ──────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="meta_glasses.py", description="Ray-Ban Meta glasses through the Jarvis phone.")
    parser.add_argument("--device", help="phone to use: paired device id, id prefix, or name substring")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="seconds to wait for the phone")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="battery, worn/folded, heat, storage, recording, volume, settings")
    sub.add_parser("look", help="what the camera can do now; the live frame while streaming")
    p = sub.add_parser("photo", help="take a photo for vision (the capture LED lights)")
    p.add_argument("--question", help="what to look for in it")
    p = sub.add_parser("video", help="record a clip")
    p.add_argument("--seconds", type=int, help="1-180 (capped by the glasses' clip length)")
    p = sub.add_parser("live", help="start or stop the live stream to the phone")
    p.add_argument("action", choices=("start", "stop"))
    p = sub.add_parser("speak", help="say text through the glasses' speakers")
    p.add_argument("text")
    p = sub.add_parser("volume", help="speaker volume")
    p.add_argument("level", type=int)
    sub.add_parser("talk", help="open the glasses' assistant")
    p = sub.add_parser("media", help="list, latest-photo or import")
    p.add_argument("action", choices=("list", "latest-photo", "import"))
    p.add_argument("--question", help="for latest-photo: what to look for")
    p = sub.add_parser("settings", help="read or change clip length and video mode")
    p.add_argument("--clip-length", dest="clip_length", type=int, choices=CLIP_LENGTHS)
    p.add_argument("--video-mode", dest="video_mode", choices=VIDEO_MODES)
    return parser


def _run(glasses: MetaGlasses, args: argparse.Namespace) -> dict[str, Any]:
    command = args.command
    if command == "status":
        return glasses.status()
    if command == "look":
        return glasses.look()
    if command == "photo":
        return glasses.photo(question=args.question)
    if command == "video":
        return glasses.video(seconds=args.seconds)
    if command == "live":
        return glasses.live(args.action)
    if command == "speak":
        return glasses.speak(args.text)
    if command == "volume":
        return glasses.volume(args.level)
    if command == "talk":
        return glasses.talk()
    if command == "media":
        return glasses.media(args.action.replace("-", "_"), question=args.question)
    if command == "settings":
        return glasses.settings(clip_length_seconds=args.clip_length, video_mode=args.video_mode)
    raise MetaGlassesError(f"unknown command {command!r}")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = _run(MetaGlasses(device=args.device, timeout=args.timeout), args)
    except MetaGlassesError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    if isinstance(result.get("base64"), str):
        result = {**result, "base64": f"<{len(result['base64'])} base64 chars>"}
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
