"""Holo Drop: fling links, photos, files and text onto any of your devices.

Share → Holo Drop (or Back Tap / Control Center on the iPhone; a shortcut, trackpad flick or the
menu bar on the Mac) opens an Orbit with your devices around the item; fling it toward one or
tap it. Drops go direct over the local network when they can, otherwise through Jarvis (held
and delivered when a device is back; a Mac is woken). Off: the routes refuse, Jarvis's
holo_drop tool is refused, and every device hides its Holo Drop entry points.
"""
from __future__ import annotations

import threading

from jarvis_power import Link, PowerIntegration, Setting


class HoloDrop(PowerIntegration):
    id = "holo-drop"
    name = "Holo Drop"
    icon = "hand.point.up.braille.fill"
    summary = "Fling links, photos, files and text onto any of your devices."
    processes = ("webui",)
    toolsets = ("holo_drop",)
    route_prefixes = ("/api/holo-drop",)
    surfaces = ("ios.share.holo_drop", "ios.trigger.holo_drop", "mac.share.holo_drop",
                "mac.trigger.holo_drop", "web.holo_drop")
    links = (Link("ios", "holo_drop", "Holo Drop something"), Link("ios", "holo_drop_page", "Saved, arrival & Back Tap"),
             Link("web", "holo_drop", "Holo Drop something"))
    settings = (
        Setting("direct", "Send directly on the same Wi-Fi", "toggle", default=True,
                help="Fastest, no size limit. Otherwise drops go through Jarvis."),
        Setting("max_mb", "Largest drop through Jarvis", "number", default=500, min=1, max=2000,
                unit="MB", jarvis="never"),
        Setting("defaults", "Arrival defaults (per device)", "text", default="",
                help="Set from each device's picker; save, open, copy, save_open or save_copy."),
    )
    actions = ("refresh",)
    _stop: threading.Event | None = None

    def start(self, process: str) -> None:
        stop = threading.Event()
        type(self)._stop = stop

        def loop():
            # Sweep first (an expired drop must never be delivered), at once, then every 30 s.
            while True:
                try:
                    from api import holo_drop_routes
                    holo_drop_routes.sweep_and_tell()
                    holo_drop_routes.deliver_held()
                except Exception:
                    pass
                if stop.wait(30):
                    return

        threading.Thread(target=loop, name="holo-drop-sweeper", daemon=True).start()

    def stop(self, process: str) -> None:
        if type(self)._stop is not None:
            type(self)._stop.set()
        try:                                       # nothing outlives its 24 h while switched off
            from api import holo_drop_routes
            holo_drop_routes.sweep_and_tell()
        except Exception:
            pass

    def _today(self) -> list[dict]:
        import time
        from api.holo_drop_store import store
        since = time.time() - 86400
        return [d for d in store().history(200) if (d.get("created") or 0) >= since]

    def status_line(self) -> str:
        n = len(self._today())
        return f"{n} drop{'s' if n != 1 else ''} today" if n else "Nothing dropped today"

    def state(self) -> dict:
        today = self._today()
        last = today[0] if today else None
        what = (last.get("name") or last.get("title") or last.get("url") or last.get("text") or "")[:60] if last else ""
        return {"today": len(today), "last": what or "—", "last_state": (last or {}).get("outcome") or "",
                "status": self.status_line()}

    def action(self, name: str, event: dict) -> dict:
        if name == "refresh":
            return {"state": self.state()}
        return {"error": f"unknown action {name!r}"}
