"""Game streaming tools — Jarvis runs Sunshine + Moonlight on the gaming PC: see status and
paired devices, start a game streaming to a device, stop it, and pair/unpair Moonlight clients.

game_stream_status   reachable, the live stream (if any), paired devices, available games
game_stream_start    start a game streaming to a device (wakes the PC if asleep)
game_stream_stop     stop the running stream
game_stream_pair     answer a waiting Moonlight pair request with its PIN  |  game_stream_unpair  remove a device

Every call goes to the webui over the host-signed loopback (/api/game-streaming), the same routes
the iPhone and web use. The server readies the Sunshine host and points the target's Moonlight at
it; a stream is client-initiated, so "start" means ready-the-host + connect-the-device.
"""
from __future__ import annotations

import difflib
import json

from tools.chrome_device_tool import _api_request
from tools.registry import registry


def _status():
    return _api_request("GET", "/api/game-streaming/status")


def _match_game(name, apps):
    names = [a.get("name", "") if isinstance(a, dict) else str(a) for a in (apps or [])]
    if not name or not names:
        return name
    for n in names:
        if n.lower() == name.lower():
            return n
    close = difflib.get_close_matches(name, names, n=1, cutoff=0.4)
    if close:
        return close[0]
    for n in names:
        if name.lower() in n.lower():
            return n
    return name


def game_stream_status(args, **kw):
    return json.dumps(_status())


def game_stream_start(args, **kw):
    target = args.get("target") or args.get("device") or ""
    game = args.get("game") or args.get("app") or ""
    game = _match_game(game, _status().get("apps"))
    return json.dumps(_api_request("POST", "/api/game-streaming/start", {"target": target, "game": game}))


def game_stream_stop(args, **kw):
    return json.dumps(_api_request("POST", "/api/game-streaming/stop", {"target": args.get("target", "")}))


NO_PENDING_DETAIL = ("No device is waiting to pair. Open Moonlight on the device and tap your "
                     "PC — it shows a 4-digit PIN — then give me that PIN.")


def game_stream_pair(args, **kw):
    """Sunshine pairs one waiting request (a Moonlight client that tapped the PC and shows a
    PIN). Without a pairing_id, check something is waiting first, so a PIN is never sent
    blind; the PC picks the only waiting request (or the one named like the device)."""
    body = {"device": args.get("device", ""), "pin": str(args.get("pin", "") or "").strip()}
    pairing_id = str(args.get("pairing_id") or "").strip()
    if pairing_id:
        body["pairing_id"] = pairing_id
    else:
        pending = _api_request("GET", "/api/game-streaming/pairings")
        if pending.get("offline") or pending.get("needs_login") or pending.get("_error"):
            return json.dumps(pending)
        if pending.get("ok") and not pending.get("pairings"):
            return json.dumps({"ok": False, "detail": NO_PENDING_DETAIL})
    return json.dumps(_api_request("POST", "/api/game-streaming/pair", body))


def game_stream_unpair(args, **kw):
    return json.dumps(_api_request("POST", "/api/game-streaming/unpair",
                                   {"device": args.get("device") or args.get("uuid", "")}))


registry.register(
    name="game_stream_status", toolset="game_streaming", emoji="🎮",
    schema={"name": "game_stream_status",
            "description": "Show Sunshine game-streaming status: reachable, the live stream if any, paired Moonlight devices and available games.",
            "parameters": {"type": "object", "properties": {}}},
    handler=lambda args, **kw: game_stream_status(args, **kw))

registry.register(
    name="game_stream_start", toolset="game_streaming", emoji="🎮",
    schema={"name": "game_stream_start",
            "description": "Start streaming a game to a device, e.g. 'stream Cyberpunk to the Mac'. Wakes the PC if asleep and connects the device's Moonlight.",
            "parameters": {"type": "object", "properties": {
                "target": {"type": "string", "description": "Target device name (e.g. Mac, TV, iPhone)."},
                "game": {"type": "string", "description": "Game/app name; fuzzy-matched to Sunshine's app list."}},
                "required": ["target"]}},
    handler=lambda args, **kw: game_stream_start(args, **kw))

registry.register(
    name="game_stream_stop", toolset="game_streaming", emoji="🎮",
    schema={"name": "game_stream_stop",
            "description": "Stop the running game stream.",
            "parameters": {"type": "object", "properties": {
                "target": {"type": "string", "description": "Optional target device to stop."}}}},
    handler=lambda args, **kw: game_stream_stop(args, **kw))

registry.register(
    name="game_stream_pair", toolset="game_streaming", emoji="🎮",
    schema={"name": "game_stream_pair",
            "description": "Pair a new Moonlight device: on the device, open Moonlight and tap the PC — it shows a 4-digit PIN — then submit that PIN here.",
            "parameters": {"type": "object", "properties": {
                "device": {"type": "string", "description": "A name for the new device."},
                "pin": {"type": "string", "description": "The PIN shown by Moonlight on the device."},
                "pairing_id": {"type": "string", "description": "Optional: which waiting device to pair, when several are waiting (from the reply's pairings list)."}},
                "required": ["pin"]}},
    handler=lambda args, **kw: game_stream_pair(args, **kw))

registry.register(
    name="game_stream_unpair", toolset="game_streaming", emoji="🎮",
    schema={"name": "game_stream_unpair",
            "description": "Unpair / remove a Moonlight device from the Sunshine host.",
            "parameters": {"type": "object", "properties": {
                "device": {"type": "string", "description": "The device name or uuid to remove."}},
                "required": ["device"]}},
    handler=lambda args, **kw: game_stream_unpair(args, **kw))
