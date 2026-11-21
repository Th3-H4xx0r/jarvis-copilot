"""Game Streaming: stream the gaming PC's games to the Mac, an Android TV and the iPhone with
Sunshine (host) + Moonlight (clients), and let Jarvis orchestrate it.

The PC's jc-client talks to Sunshine's local API and tails its log; the server (api.game_streaming_routes)
holds live state + session history, dispatches start/stop/pair/unpair, and sends alerts. A stream is
client-initiated, so "start" readies the host (waking the PC if asleep) and points the target's Moonlight
at it. Off: the PC's watcher stops, the routes refuse and the tools are refused; paired devices + config stay.
"""
from __future__ import annotations

from jarvis_power import PowerIntegration, Setting


class GameStreaming(PowerIntegration):
    id = "game-streaming"
    name = "Game Streaming"
    icon = "gamecontroller"
    summary = "Stream your PC's games to your devices with Sunshine + Moonlight, and let Jarvis start them."
    default_enabled = True
    protected = False
    processes = ("webui",)
    toolsets = ("game_streaming",)
    route_prefixes = ("/api/game-streaming",)
    surfaces = ("ios.game_streaming", "web.game_streaming", "windows.game_streaming")
    settings = (
        Setting("host", "Sunshine PC address", "text", default="",
                help="Your gaming PC's address (Tailscale name or IP) where Sunshine answers.", jarvis="never"),
        Setting("port", "Sunshine web port", "number", default=47990, jarvis="never"),
        Setting("user", "Sunshine username", "text", default="", jarvis="never"),
        Setting("password", "Sunshine password", "secret", jarvis="never"),
        Setting("wake_timeout", "Give up waking the PC after", "number", default=1200, unit="s", jarvis="never"),
        Setting("targets", "Target devices (JSON)", "text", default="[]",
                help='Moonlight targets, e.g. [{"name":"Mac","kind":"mac","host":"gpc"}].', jarvis="never"),
        Setting("log_path", "Sunshine log path", "text", default="",
                help="Override where Sunshine writes its log; blank uses the per-OS default.", jarvis="never"),
    )
    actions = ("refresh",)

    def start(self, process: str) -> None:
        try:
            from api import game_streaming_routes
            game_streaming_routes.power_changed(True)
        except Exception:  # noqa: BLE001
            pass

    def stop(self, process: str) -> None:
        try:
            from api import game_streaming_routes
            game_streaming_routes.power_changed(False)
        except Exception:  # noqa: BLE001
            pass

    def status_line(self) -> str:
        try:
            from api import game_streaming_routes as R
            live = R.store().get_live()
            if live.get("active"):
                return f"Streaming {live.get('app') or 'a game'}"
        except Exception:  # noqa: BLE001
            pass
        return "Idle"
