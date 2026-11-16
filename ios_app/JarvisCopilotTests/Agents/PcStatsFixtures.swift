import Foundation
@testable import JarvisCopilot

/// The server's v4 default dashboards and catalog (webui/api/pc_stats_catalog.py) with a
/// realistic busy PC: GPU 98 % / 65°, CPU 43 % / 46°, 120 fps, ten temperatures, four fans,
/// 256 W. Used by the layout tests and the rendered previews.
@MainActor
enum PcStatsFixtures {
    static let dashboardsJSON = #"""
{"dashboards": [{"id": "overview", "name": "Overview", "auto": null, "widgets": [{"id": "gpu", "kind": "hero", "x": 0, "y": 0, "w": 4, "h": 4, "readings": ["gpu.load"], "style": {"label": "GPU", "chart": "area", "meta": ["gpu.temp", "gpu.clock", "gpu.power", "gpu.vram_used"], "warn": 85, "crit": 95}}, {"id": "cpu", "kind": "hero", "x": 4, "y": 0, "w": 4, "h": 4, "readings": ["cpu.load"], "style": {"label": "CPU", "chart": "area", "meta": ["cpu.temp", "cpu.clock", "cpu.power"], "warn": 90, "crit": 100}}, {"id": "gpudetail", "kind": "stats", "x": 8, "y": 0, "w": 4, "h": 4, "readings": ["gpu.clock", "gpu.mem_clock", "gpu.power", "gpu.fan", "gpu.hotspot", "gpu.vram_used"], "style": {"label": "Graphics card"}}, {"id": "frames", "kind": "number", "x": 0, "y": 4, "w": 3, "h": 3, "readings": ["fps"], "style": {"label": "Frame rate", "chart": "area"}}, {"id": "frametime", "kind": "number", "x": 3, "y": 4, "w": 3, "h": 3, "readings": ["frametime"], "style": {"label": "Frame time", "chart": "line"}}, {"id": "watts", "kind": "number", "x": 6, "y": 4, "w": 3, "h": 3, "readings": ["power.total"], "style": {"label": "Power", "chart": "area"}}, {"id": "memory", "kind": "bars", "x": 9, "y": 4, "w": 3, "h": 3, "readings": ["ram.used", "ram.commit", "gpu.vram_used", "disk.used"], "style": {"label": "Memory", "meta": ["ram.used"]}}, {"id": "temps", "kind": "bars", "x": 0, "y": 7, "w": 3, "h": 3, "readings": ["cpu.temp", "gpu.temp", "gpu.hotspot", "temp.*"], "style": {"label": "Temperatures"}}, {"id": "cooling", "kind": "bars", "x": 3, "y": 7, "w": 3, "h": 3, "readings": ["gpu.fan", "fan.*"], "style": {"label": "Cooling"}}, {"id": "network", "kind": "chart", "x": 6, "y": 7, "w": 3, "h": 3, "readings": ["net.down", "net.up"], "style": {"label": "Network", "chart": "line", "window": 600}}, {"id": "disk", "kind": "chart", "x": 9, "y": 7, "w": 3, "h": 3, "readings": ["disk.read", "disk.write"], "style": {"label": "Disk", "chart": "line", "window": 600}}]}, {"id": "gaming", "name": "Gaming", "auto": "game", "widgets": [{"id": "fps", "kind": "hero", "x": 0, "y": 0, "w": 6, "h": 4, "readings": ["fps"], "style": {"label": "Frame rate", "chart": "area", "meta": ["fps.low1", "frametime"]}}, {"id": "gpuload", "kind": "ring", "x": 6, "y": 0, "w": 2, "h": 2, "readings": ["gpu.load"], "style": {"label": "GPU"}}, {"id": "cpuload", "kind": "ring", "x": 6, "y": 2, "w": 2, "h": 2, "readings": ["cpu.load"], "style": {"label": "CPU"}}, {"id": "perf", "kind": "stats", "x": 8, "y": 0, "w": 4, "h": 4, "readings": ["fps.low1", "frametime", "gpu.clock", "cpu.clock", "gpu.power", "gpu.vram_used"], "style": {"label": "Performance"}}, {"id": "gputemp", "kind": "number", "x": 0, "y": 4, "w": 3, "h": 3, "readings": ["gpu.temp"], "style": {"label": "GPU temperature", "warn": 85, "crit": 95}}, {"id": "cputemp", "kind": "number", "x": 3, "y": 4, "w": 3, "h": 3, "readings": ["cpu.temp"], "style": {"label": "CPU temperature", "warn": 90, "crit": 100}}, {"id": "watts", "kind": "number", "x": 6, "y": 4, "w": 3, "h": 3, "readings": ["power.total"], "style": {"label": "Power"}}, {"id": "frametime", "kind": "number", "x": 9, "y": 4, "w": 3, "h": 3, "readings": ["frametime"], "style": {"label": "Frame time", "chart": "line"}}, {"id": "load", "kind": "chart", "x": 0, "y": 7, "w": 6, "h": 3, "readings": ["gpu.load", "cpu.load"], "style": {"label": "Load", "chart": "area", "window": 600}}, {"id": "tempchart", "kind": "chart", "x": 6, "y": 7, "w": 3, "h": 3, "readings": ["gpu.temp", "cpu.temp"], "style": {"label": "Temperatures", "chart": "line", "window": 600}}, {"id": "session", "kind": "session", "x": 9, "y": 7, "w": 3, "h": 3, "readings": [], "style": {"label": "Game session"}}]}, {"id": "power", "name": "Power", "auto": null, "widgets": [{"id": "total", "kind": "hero", "x": 0, "y": 0, "w": 6, "h": 4, "readings": ["power.total"], "style": {"label": "Power", "chart": "area", "meta": ["power.gpu", "power.cpu"]}}, {"id": "split", "kind": "bars", "x": 6, "y": 0, "w": 3, "h": 4, "readings": ["power.gpu", "power.cpu", "power.ram", "power.disk", "power.net"], "style": {"label": "By part"}}, {"id": "measured", "kind": "stats", "x": 9, "y": 0, "w": 3, "h": 4, "readings": ["gpu.power", "cpu.power", "gpu.clock", "cpu.clock"], "style": {"label": "Measured"}}, {"id": "history", "kind": "chart", "x": 0, "y": 4, "w": 12, "h": 3, "readings": ["power.total", "power.gpu", "power.cpu"], "style": {"label": "Last hour", "chart": "line", "window": 3600}}, {"id": "gpupower", "kind": "number", "x": 0, "y": 7, "w": 4, "h": 3, "readings": ["gpu.power"], "style": {"label": "GPU power", "chart": "area"}}, {"id": "cpupower", "kind": "number", "x": 4, "y": 7, "w": 4, "h": 3, "readings": ["cpu.power"], "style": {"label": "CPU power", "chart": "area"}}, {"id": "load", "kind": "chart", "x": 8, "y": 7, "w": 4, "h": 3, "readings": ["gpu.load", "cpu.load"], "style": {"label": "Load", "chart": "line", "window": 600}}]}]}
"""#

    static let catalogJSON = #"""
{"readings": {"cpu.load": {"label": "CPU load", "unit": "%", "group": "cpu", "estimated": false}, "cpu.temp": {"label": "CPU temperature", "unit": "°C", "group": "cpu", "estimated": false}, "cpu.clock": {"label": "CPU clock", "unit": "MHz", "group": "cpu", "estimated": false}, "cpu.power": {"label": "CPU power", "unit": "W", "group": "cpu", "estimated": false}, "gpu.load": {"label": "GPU load", "unit": "%", "group": "gpu", "estimated": false}, "gpu.temp": {"label": "GPU temperature", "unit": "°C", "group": "gpu", "estimated": false}, "gpu.hotspot": {"label": "GPU memory junction", "unit": "°C", "group": "gpu", "estimated": false}, "gpu.clock": {"label": "GPU clock", "unit": "MHz", "group": "gpu", "estimated": false}, "gpu.mem_clock": {"label": "GPU memory clock", "unit": "MHz", "group": "gpu", "estimated": false}, "gpu.power": {"label": "GPU power", "unit": "W", "group": "gpu", "estimated": false}, "gpu.fan": {"label": "GPU fan", "unit": "rpm", "group": "gpu", "estimated": false}, "gpu.vram_used": {"label": "VRAM used", "unit": "GB", "group": "gpu", "estimated": false}, "gpu.vram_total": {"label": "VRAM total", "unit": "GB", "group": "gpu", "estimated": false}, "fps": {"label": "Frame rate", "unit": "fps", "group": "frames", "estimated": false}, "fps.low1": {"label": "1% low", "unit": "fps", "group": "frames", "estimated": false}, "frametime": {"label": "Frame time", "unit": "ms", "group": "frames", "estimated": false}, "ram.used": {"label": "RAM used", "unit": "GB", "group": "memory", "estimated": false}, "ram.total": {"label": "RAM total", "unit": "GB", "group": "memory", "estimated": false}, "ram.commit": {"label": "Committed memory", "unit": "GB", "group": "memory", "estimated": false}, "disk.used": {"label": "System drive used", "unit": "%", "group": "disk", "estimated": false}, "disk.read": {"label": "Disk read", "unit": "MB/s", "group": "disk", "estimated": false}, "disk.write": {"label": "Disk write", "unit": "MB/s", "group": "disk", "estimated": false}, "net.down": {"label": "Download", "unit": "MB/s", "group": "network", "estimated": false}, "net.up": {"label": "Upload", "unit": "MB/s", "group": "network", "estimated": false}, "power.cpu": {"label": "CPU power (model)", "unit": "W", "group": "power", "estimated": false}, "power.gpu": {"label": "GPU power (model)", "unit": "W", "group": "power", "estimated": false}, "power.ram": {"label": "RAM power", "unit": "W", "group": "power", "estimated": true}, "power.disk": {"label": "Disk power", "unit": "W", "group": "power", "estimated": true}, "power.net": {"label": "Network power", "unit": "W", "group": "power", "estimated": true}, "power.total": {"label": "PC (est.)", "unit": "W", "group": "power", "estimated": true}}, "columns": 12}
"""#

    static func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    static var dashboards: [PcDashboard] { PcDashboard.list(json(dashboardsJSON)) }
    static var catalog: PcCatalog { PcCatalog(json: json(catalogJSON)) }

    static let values: [String: Double] = [
        "gpu.load": 98, "gpu.temp": 65, "gpu.hotspot": 78, "gpu.clock": 2745, "gpu.mem_clock": 11_502, "gpu.power": 187,
        "gpu.fan": 1640, "gpu.vram_used": 8.9, "gpu.vram_total": 16,
        "cpu.load": 43, "cpu.temp": 46, "cpu.clock": 5300, "cpu.power": 48,
        "fps": 120, "fps.low1": 96, "frametime": 8.3,
        "ram.used": 21.4, "ram.total": 32, "ram.commit": 27.1, "disk.used": 61, "disk.read": 12.4, "disk.write": 3.1,
        "net.down": 42.5, "net.up": 3.2,
        "power.cpu": 48, "power.gpu": 187, "power.ram": 5, "power.disk": 0.4, "power.net": 0.6, "power.total": 256,
        "temp.motherboard": 38, "temp.chipset": 52, "temp.vrm_mos": 57, "temp.nvme_ssd_samsung_990_pro": 44,
        "temp.ram_dimm_a2": 41, "temp.pch": 49, "temp.system_2": 35,
        "fan.cpu_fan": 1180, "fan.pump": 2400, "fan.system_fan_1": 900, "fan.system_fan_2": 880,
    ]

    static var live: PcLive {
        PcLive(deviceId: "pc", name: "pranav-computer", online: true, at: Date(), values: values,
               game: "cod.exe", estimated: ["power.cpu", "power.gpu", "power.total"], hasSample: true)
    }

    static func series(_ key: String, now: Double, window: Int) -> [PcPoint] {
        let base = values[key] ?? 1
        let n = min(150, max(30, window / 4))
        return (0..<n).map { i in
            let t = now - Double(window) + Double(window) * Double(i) / Double(n - 1)
            let wave = sin(Double(i) / 7 + Double(key.count)) * 0.06 + cos(Double(i) / 17) * 0.04
            let cap = key.hasSuffix(".load") ? 100.0 : .infinity
            return PcPoint(t: t, avg: min(cap, max(0, base * (1 + wave))), min: base * 0.9, max: min(cap, base * 1.08))
        }
    }

    /// A model filled as if the page had loaded, on the given dashboard.
    static func model(dashboard id: String) -> PcStatsModel {
        let m = PcStatsModel(deviceId: "pc", name: "pranav-computer", defaults: UserDefaults(suiteName: "pcstats-fixture")!)
        let boards = dashboards
        let now = Date().timeIntervalSince1970
        var s: [PcSeriesKey: [PcPoint]] = [:]
        for b in boards {
            for w in b.widgets where w.kind.hasChart {
                let window = PcRange.live.window(for: w)
                for k in PcFormat.expand(w.readings, live: live) { s[PcSeriesKey(key: k, window: window)] = series(k, now: now, window: window) }
            }
        }
        let session = PcSession(json: ["id": "s1", "exe": "cod.exe", "title": "Call of Duty", "start": now - 7_800,
                                       "end": now - 600, "fps_avg": 118.4, "fps_low1": 91, "cpu_temp_max": 61,
                                       "gpu_temp_max": 71, "energy_wh": 512, "watts_avg": 251, "watts_max": 298, "throttle_s": 0])!
        let moment = PcMoment(json: ["id": "m1", "t": now - 3_000, "key": "gpu.temp", "value": 86, "threshold": 85,
                                     "kind": "hot", "duration_s": 12, "label": ""])!
        let energy = PcEnergy(json: ["buckets": (0..<14).map { i in ["start": now - Double(13 - i) * 86_400,
                                                                     "kwh": 1.2 + Double(i % 4) * 0.6, "cost": 0.3] },
                                     "price": 0.15, "currency": "USD"])
        var health: [String: [PcPoint]] = [:]
        for k in ["cpu.temp", "gpu.temp", "gpu.fan", "fan.cpu_fan", "fan.pump", "fan.system_fan_1", "fan.system_fan_2"] {
            health[k] = series(k, now: now, window: 90 * 86_400)
        }
        m.seed(live: live, catalog: catalog, dashboards: boards, activeId: id, series: s, sessions: [session],
               moments: [moment], energy: energy, health: health)
        return m
    }
}
