"""PC Stats: a live dashboard of the gaming PC on a side monitor, the phone and the web, with
history on the server and whole-PC watts (WattSeal's model, reimplemented).

The PC's Jarvis app reads the sensors (its JarvisSensors helper), draws the side-monitor
dashboard and uploads samples to /api/pc-stats; the server keeps rolled-up history, game
sessions, marked moments and the dashboards, and Jarvis reads and edits them with the
pc_stats tools. Off: the routes refuse, the tools are refused, the PC stops collecting and
closes its window, and the phone and web hide the PC card's numbers and the stats page.
"""
from __future__ import annotations

import threading

from jarvis_power import PowerIntegration, Setting


class PcStats(PowerIntegration):
    id = "pc-stats"
    name = "PC Stats"
    icon = "gauge.with.dots.needle.67percent"
    summary = "A live dashboard of your PC on a side monitor, your phone and the web, with history and watts."
    default_enabled = True
    processes = ("webui",)
    toolsets = ("pc_stats",)
    route_prefixes = ("/api/pc-stats",)
    surfaces = ("ios.pc_stats", "web.pc_stats", "windows.pc_stats")
    settings = (
        Setting("monitor", "Show the dashboard on", "text", default="",
                help="The PC display name (e.g. DISPLAY2). Empty: no window, history still records."),
        Setting("open_at_login", "Open the dashboard when the PC signs in", "toggle", default=True),
        Setting("price", "Electricity price", "number", default=0.15, min=0, max=5, unit="per kWh"),
        Setting("currency", "Currency", "text", default="USD"),
        Setting("psu_efficiency", "Power supply efficiency", "number", default=90, min=50, max=100, unit="%",
                help="Turns the parts' watts into what the PC draws from the wall."),
        Setting("history", "Keep history on the server", "toggle", default=True),
        Setting("interval", "Read the sensors every", "number", default=1, min=1, max=10, unit="s"),
        Setting("cpu_tdp", "CPU TDP for estimates", "number", default=0, min=0, max=500, unit="W",
                help="0 uses the CPU's own table value. Only used when power can't be measured."),
        Setting("gpu_tdp", "GPU TDP for estimates", "number", default=0, min=0, max=1000, unit="W"),
        Setting("sensor_driver", "Use the sensor driver (PawnIO)", "toggle", default=True,
                help="Reads CPU temperature, fans and CPU power. It's a kernel driver; some anti-cheat may flag it.",
                jarvis="ask"),
        Setting("warn_gpu_temp", "Mark GPU temperature above", "number", default=85, min=50, max=110, unit="°C"),
        Setting("warn_cpu_temp", "Mark CPU temperature above", "number", default=95, min=50, max=110, unit="°C"),
        Setting("warn_power_spike", "Mark power spikes above", "number", default=1.3, min=1.05, max=3,
                unit="× the hour's average"),
        Setting("warn_fps_drop", "Mark frame-rate drops of", "number", default=40, min=10, max=90, unit="%"),
    )
    actions = ("refresh",)
    _stop: threading.Event | None = None

    def start(self, process: str) -> None:
        stop = threading.Event()
        type(self)._stop = stop

        def loop():
            while not stop.wait(3600):
                try:
                    from api.pc_stats_store import store
                    store().prune()
                except Exception:
                    pass

        threading.Thread(target=loop, name="pc-stats-prune", daemon=True).start()

    def stop(self, process: str) -> None:
        if type(self)._stop is not None:
            type(self)._stop.set()

    def _latest(self) -> dict | None:
        try:
            from api.pc_stats_store import store
            devices = store().devices()
            return store().latest(devices[0]["device_id"]) if devices else None
        except Exception:
            return None

    def status_line(self) -> str:
        latest = self._latest()
        if not latest:
            return "Waiting for the PC"
        r = latest.get("r") or {}
        bits = []
        if "cpu.load" in r:
            bits.append(f"CPU {r['cpu.load']:.0f}%")
        if "gpu.load" in r:
            bits.append(f"GPU {r['gpu.load']:.0f}%")
        if "power.total" in r:
            bits.append(f"{r['power.total']:.0f} W")
        return " · ".join(bits) or "Reporting"

    def state(self) -> dict:
        latest = self._latest() or {}
        r = latest.get("r") or {}
        return {"cpu": f"{r['cpu.load']:.0f}%" if "cpu.load" in r else "—",
                "gpu": f"{r['gpu.load']:.0f}%" if "gpu.load" in r else "—",
                "watts": f"{r['power.total']:.0f} W" if "power.total" in r else "—"}

    def action(self, name: str, event: dict) -> dict:
        if name == "refresh":
            return {"state": self.state()}
        return {"error": f"unknown action {name!r}"}
