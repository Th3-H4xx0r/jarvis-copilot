"""The dashcam: clips from the Affver A4, synced and uploaded to Drive.

Off: the server's upload relay (and its rclone) stops, /api/dashcam refuses, and
the phone stops its Wi-Fi watcher, motion detection and uploads and hides the
dashcam card, Live Activity and CarPlay screens. Clips are kept.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration


class Dashcam(PowerIntegration):
    id = "dashcam"
    name = "Dashcam"
    icon = "camera.fill"
    summary = "Clips from your dashcam, synced over its Wi-Fi and uploaded to Drive."
    processes = ("webui",)
    route_prefixes = ("/api/dashcam",)
    surfaces = ("ios.devices.dashcam", "ios.bg.dashcam", "ios.carplay.dashcam",
                "ios.liveactivity.dashcam")
    links = (Link("ios", "dashcam_page", "Open Dashcam"),)

    def stop(self, process: str) -> None:
        from api import dashcam_relay
        worker = dashcam_relay._worker
        if worker is not None:
            worker.stop()
        dashcam_relay._worker = None
        relay = getattr(dashcam_relay, "_relay", None)
        if relay is not None:
            relay.shutdown()
