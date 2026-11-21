"""PC Lighting: colour the gaming PC's fans, cooler and strip part by part from the iPhone, the web
and Jarvis, through OpenRGB on the PC (docs/superpowers/specs/2026-11-20-pc-lighting-model-specs-design.md).

The server keeps the lighting state + LED map (api.pc_lighting_store); the PC's jc-client renders
every frame with Jarvis's own effects and drives OpenRGB; the iPhone runs the same maths on the 3D
model. Off: the PC stops driving the lights (OpenRGB keeps running, so they keep their last colours),
the routes refuse and the tools are refused. The Specs screen and the PC card are not part of this.
"""
from __future__ import annotations

from jarvis_power import PowerIntegration, Setting


class PcLighting(PowerIntegration):
    id = "pc-lighting"
    name = "PC Lighting"
    icon = "rainbow"
    summary = "Colour your PC's fans, cooler and strip part by part from your phone, the web or Jarvis, through OpenRGB."
    default_enabled = True
    processes = ("webui",)
    toolsets = ("pc_lighting",)
    route_prefixes = ("/api/pc-lighting",)
    surfaces = ("ios.pc_lighting", "web.pc_lighting", "windows.pc_lighting")
    settings = (
        Setting("address", "OpenRGB address", "text", default="127.0.0.1:6742",
                help="Where OpenRGB's SDK server answers, as seen from the PC. The default is OpenRGB on the PC itself.",
                jarvis="never"),
    )
    actions = ("refresh",)

    def start(self, process: str) -> None:
        try:
            from api import pc_lighting_routes
            pc_lighting_routes.power_changed(True)
        except Exception:  # noqa: BLE001
            pass

    def stop(self, process: str) -> None:
        try:
            from api import pc_lighting_routes
            pc_lighting_routes.power_changed(False)
        except Exception:  # noqa: BLE001
            pass

    def _summary(self) -> dict:
        try:
            from api import pc_lighting_routes
            return pc_lighting_routes.summary()
        except Exception:  # noqa: BLE001
            return {"device_id": "", "online": False}

    def status_line(self) -> str:
        s = self._summary()
        if not s.get("device_id") or not s.get("online"):
            return "Waiting for the PC"
        if not s.get("mapped"):
            return "Set up lighting"
        if not s.get("on"):
            return "Lights off"
        return f"{str(s.get('effect') or 'static').title()} · {s.get('brightness', 100)}%"

    def state(self) -> dict:
        s = self._summary()
        return {"status": self.status_line(), "brightness": f"{s.get('brightness', '—')}%" if s.get("mapped") else "—"}

    def action(self, name: str, event: dict) -> dict:
        if name == "refresh":
            return {"state": self.state()}
        return {"error": f"unknown action {name!r}"}
