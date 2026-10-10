"""toyota_status / toyota_command / toyota_climate — Jarvis's side of Pranav's car.

Everything goes through his Home Assistant's Toyota integration; nothing here talks to Toyota.
Sign-in only happens on the iPhone Car page, never through a tool.
"""
from __future__ import annotations

import json
from typing import Any, Awaitable, Callable

from plugins.toyota import service
from plugins.toyota.car import CarError, NotSignedIn, ToyotaCar
from plugins.toyota.commands import SERVICES, is_confirmed, needs_face_id
from plugins.toyota.ha import HAClient, HAError, configured

STATUS_SCHEMA = {
    "name": "toyota_status",
    "description": (
        "Pranav's car (2026 Toyota Camry SE) from Toyota's cloud: range, fuel, odometer, doors / "
        "windows / trunk locked or open, tyre pressures, health, where it's parked, whether it's "
        "remote-started, and when the car last reported. Set refresh=true only when he wants fresh "
        "data: it wakes the car (slow, and uses its battery)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "refresh": {"type": "boolean", "description": "Wake the car for fresh data first."},
        },
    },
}

COMMAND_SCHEMA = {
    "name": "toyota_command",
    "description": (
        "Send a remote command to Pranav's car through Toyota: start (remote start), stop, lock, "
        "unlock, trunk_lock, trunk_unlock, lights (headlights on), horn, buzzer, hazards_on, "
        "hazards_off. Every command except stop needs his approval with Face ID on his iPhone: this "
        "tool sends the approval to his phone and returns at once — tell him to approve it there; it "
        "runs when he does. Don't ask him out loud first, and never repeat a command on your own."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "command": {"type": "string", "enum": list(SERVICES)},
        },
        "required": ["command"],
    },
}

CLIMATE_SCHEMA = {
    "name": "toyota_climate",
    "description": (
        "The climate Pranav's car uses when remote-started. action=get reads it; action=set changes "
        "any of custom (use these settings), temp (in the car's unit, °F), defrost_front, "
        "defrost_rear. \"Start the car at 70\" = set temp 70, then toyota_command start (which still "
        "needs his yes)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["get", "set"]},
            "custom": {"type": "boolean"},
            "temp": {"type": "number"},
            "defrost_front": {"type": "boolean"},
            "defrost_rear": {"type": "boolean"},
        },
        "required": ["action"],
    },
}


def available() -> bool:
    return configured()


def _call(work: Callable[[], Awaitable[Any]]) -> str:
    try:
        return json.dumps(service.run(work()), default=str)
    except (NotSignedIn, CarError, HAError) as exc:
        return json.dumps({"error": str(exc)})


def _handle_status(args: dict, **_: Any) -> str:
    async def work() -> dict:
        ha = HAClient()
        await service.require_signed_in(ha)
        car = ToyotaCar(ha)
        fresh = None
        if is_confirmed(args.get("refresh")):
            fresh = (await car.refresh())["fresh"]
        snapshot = await car.snapshot()
        if fresh is False:
            snapshot["note"] = "The car was woken but hasn't sent its new report yet; this is its last one."
        return snapshot
    return _call(work)


def _request_approval(command: str) -> dict:
    """Ask the webui (it owns approvals and the push to his phone) over the host-signed loopback."""
    from tools.chrome_device_tool import _api_request

    return _api_request("POST", "/api/car/approvals", {"command": command}, timeout=15.0)


def _handle_command(args: dict, **_: Any) -> str:
    name = str(args.get("command") or "")
    if name not in SERVICES:
        return json.dumps({"error": f"Unknown car command '{name}'. Use one of: {', '.join(SERVICES)}."})
    if needs_face_id(name):
        answer = _request_approval(name)
        if answer.get("_error") or not answer.get("ok"):
            return json.dumps({"error": answer.get("_error") or answer.get("error")
                               or "Couldn't send the approval to his iPhone."})
        return json.dumps({"pending_approval": True, "command": name,
                           "message": "Sent to Pranav's iPhone — it runs once he approves it with Face ID "
                                      "(within 2 minutes). Tell him to check his phone."})

    async def work() -> dict:
        car = ToyotaCar(HAClient())
        await service.require_signed_in(car.ha)
        return await car.command(name)
    return _call(work)


def _handle_climate(args: dict, **_: Any) -> str:
    async def work() -> dict:
        ha = HAClient()
        await service.require_signed_in(ha)
        car = ToyotaCar(ha)
        if args.get("action") == "set":
            return await car.set_climate(custom=args.get("custom"), temp=args.get("temp"),
                                         defrost_front=args.get("defrost_front"),
                                         defrost_rear=args.get("defrost_rear"))
        snapshot = await car.snapshot()
        return {"climate": snapshot["climate"], "running": snapshot["running"]}
    return _call(work)


TOOLS = (
    ("toyota_status", STATUS_SCHEMA, _handle_status, "🚗"),
    ("toyota_command", COMMAND_SCHEMA, _handle_command, "🔑"),
    ("toyota_climate", CLIMATE_SCHEMA, _handle_climate, "🌡️"),
)
