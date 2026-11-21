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
    # Only the two things nobody can auto-detect: the Sunshine login the user set in
    # Sunshine itself. The PC's address, the Sunshine port and the device list are
    # discovered (jc-client runs on the PC), so they are not fields on the form. The
    # native "Set up" page (PowerNative.settings) owns the whole flow; the advanced
    # log-path override lives there too. Internal values (host, wake_timeout) still
    # read from the stored document for back-compat but are no longer form fields.
    settings = (
        Setting("user", "Sunshine username", "text", default="", jarvis="never",
                help="The login you set in Sunshine's own web UI."),
        Setting("password", "Sunshine password", "secret", jarvis="never",
                help="The password you set in Sunshine's own web UI."),
        Setting("log_path", "Sunshine log path", "text", default="", jarvis="never",
                help="Advanced: override where Sunshine writes its log; blank uses the per-OS default."),
    )
    actions = ("refresh",)
    native = {"ios": ("card", "page", "settings"), "web": ("settings",)}

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
