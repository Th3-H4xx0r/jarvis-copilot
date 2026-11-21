"""Proactive game-streaming alerts: a new/unknown device connecting, a stream starting or
stopping, and Sunshine going down. Dedup unknown devices; only alert "down" after the host has
been reachable at least once (so an unconfigured install doesn't spam). Best-effort; never raises.
"""
from __future__ import annotations

_SEEN_UNKNOWN: set = set()
_REACHABLE = {"val": None}


def _push(title: str, body: str, data: dict | None = None) -> int:
    try:
        from api import push
        return push.push_phones(data or {"type": "game_streaming"},
                                alert={"title": title, "body": body})
    except Exception:  # noqa: BLE001
        return 0


def _enabled() -> set:
    # All three alert kinds on for v1 (unknown / start_stop / down).
    return {"unknown", "start_stop", "down"}


def emit(ev: dict) -> None:
    ev = ev or {}
    kind = ev.get("kind")
    on = _enabled()
    try:
        if kind == "device_connect" and ev.get("unknown") and "unknown" in on:
            client = ev.get("client") or "A device"
            if client in _SEEN_UNKNOWN:
                return
            _SEEN_UNKNOWN.add(client)
            _push("New device on your PC", f"{client} connected to Sunshine.",
                  {"type": "game_streaming", "event": "unknown_device", "client": client})
        elif kind == "stream_start" and "start_stop" in on:
            app = ev.get("app") or "a game"
            where = f" to {ev.get('client')}" if ev.get("client") else ""
            _push("Game streaming started", f"Streaming {app}{where}.",
                  {"type": "game_streaming", "event": "stream_start"})
        elif kind == "stream_stop" and "start_stop" in on:
            _push("Game streaming stopped", "The stream ended.",
                  {"type": "game_streaming", "event": "stream_stop"})
    except Exception:  # noqa: BLE001
        pass


def note_reachable(reachable: bool) -> None:
    prev = _REACHABLE["val"]
    _REACHABLE["val"] = bool(reachable)
    if prev is True and reachable is False and "down" in _enabled():
        _push("Sunshine is down", "The PC's game-streaming host stopped responding.",
              {"type": "game_streaming", "event": "down"})


def reset() -> None:
    _SEEN_UNKNOWN.clear()
    _REACHABLE["val"] = None
