"""Remote Desktop: real Microsoft RDP into the Windows PC from the iPhone, the web and the Mac
(docs/superpowers/specs/2026-11-15-remote-desktop-design.md).

The PC's Jarvis app sets Windows up (RDP on, NLA, firewall scoped to Tailscale), keeps the Microsoft
account password DPAPI-encrypted and releases it per session after his Face ID. The server owns
/api/rdp: sessions with game / someone-at-the-PC warnings, the iPhone's WebSocket→TCP relay and the
web's Guacamole gateway. Off: every session closes at once, the routes refuse, and the PC's helper
switches Windows RDP off and removes the firewall rule.
"""
from __future__ import annotations

import threading

from jarvis_power import PowerIntegration, Setting


class RemoteDesktop(PowerIntegration):
    id = "remote-desktop"
    name = "Remote Desktop"
    icon = "desktopcomputer"
    summary = "Work on your Windows PC from your iPhone, the web or your Mac, signed in with Face ID."
    default_enabled = True
    processes = ("webui",)
    toolsets = ("remote_desktop",)
    route_prefixes = ("/api/rdp",)
    surfaces = ("ios.remote_desktop", "web.remote_desktop", "windows.remote_desktop", "mac.remote_desktop")
    settings = (
        Setting("idle_minutes", "Disconnect after no use for", "number", default=30, min=5, max=480, unit="min"),
        Setting("warn_game", "Warn when a game is running", "toggle", default=True,
                help="Connecting signs the PC's own screen out; the game keeps running."),
        Setting("allow_web", "Allow Remote Desktop from the web", "toggle", default=True,
                help="The web connects through a gateway on the server, which holds the password in memory "
                     "for that one connection.", jarvis="ask"),
        Setting("transfer_folder", "PC folder for files you send", "text", default="Downloads\\Jarvis"),
    )
    actions = ("refresh",)
    _stop: threading.Event | None = None

    def start(self, process: str) -> None:
        try:   # builds the store, which registers the PC's rdp_credential answers
            from api import rdp_sessions
            rdp_sessions.store()
        except Exception:  # noqa: BLE001
            pass
        stop = threading.Event()
        type(self)._stop = stop

        def loop():   # end approvals past 60 s and idle sessions even when nobody asks
            while not stop.wait(5.0):
                try:
                    from api import rdp_sessions
                    if rdp_sessions._STORE is not None:
                        rdp_sessions._STORE.sweep()
                except Exception:  # noqa: BLE001
                    pass

        threading.Thread(target=loop, name="rdp-sweep", daemon=True).start()

    def stop(self, process: str) -> None:
        if type(self)._stop is not None:
            type(self)._stop.set()
        try:
            from api import rdp_sessions
            rdp_sessions.on_off()
        except Exception:  # noqa: BLE001
            pass

    def _live(self) -> list:
        try:
            from api import rdp_sessions
            return rdp_sessions.store().live() if rdp_sessions._STORE is not None else []
        except Exception:  # noqa: BLE001
            return []

    def status_line(self) -> str:
        n = len([s for s in self._live() if s.get("state") == "connected"])
        return f"{n} session{'s' if n != 1 else ''} open" if n else "Ready"

    def state(self) -> dict:
        live = self._live()
        return {"open": str(len([s for s in live if s.get("state") == "connected"])),
                "waiting": str(len([s for s in live if s.get("state") == "approving"]))}

    def action(self, name: str, event: dict) -> dict:
        if name == "refresh":
            return {"state": self.state()}
        return {"error": f"unknown action {name!r}"}
