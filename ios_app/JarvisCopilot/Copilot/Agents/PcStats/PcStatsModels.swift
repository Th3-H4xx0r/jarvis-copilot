import Foundation

// PC Stats (2026-11-15): the server's shapes (webui/api/pc_stats_routes.py,
// pc_stats_catalog.py, pc_stats_store.py) and the pure rules the phone draws by —
// how a grid dashboard reflows into one column and goes back onto the grid, and how
// a reading is written ("unavailable", never 0; "est." for estimates).

// MARK: - Small JSON readers

enum PcJSON {
    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func maps(_ v: Any?) -> [[String: Any]] { (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    static func text(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, !(v is Bool) { return n.stringValue }
        return nil
    }
    static func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }
    /// A JSON number (never a Bool), or nil for null / missing / NaN.
    static func double(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            if let s = v as? String { return Double(s) }
            return nil
        }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    static func int(_ v: Any?) -> Int? { double(v).map { Int($0.rounded()) } }
    static func bool(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false) }
    static func date(_ v: Any?) -> Date? { double(v).map { Date(timeIntervalSince1970: $0) } }
}

// MARK: - Catalog

/// One reading the PC can report (`READINGS` in pc_stats_catalog.py).
struct PcReading: Equatable, Hashable {
    let key: String
    let label: String
    let unit: String
    let group: String
    let estimated: Bool
}

/// `GET /api/pc-stats/catalog` → `{readings, widget_kinds, columns}`.
struct PcCatalog: Equatable {
    var readings: [String: PcReading]
    var kinds: [PcWidgetKind]
    var columns: Int

    static let empty = PcCatalog(readings: [:], kinds: PcWidgetKind.allCases, columns: PcLayout.columns)

    init(readings: [String: PcReading], kinds: [PcWidgetKind], columns: Int) {
        self.readings = readings
        self.kinds = kinds
        self.columns = columns
    }

    init(json: [String: Any]) {
        var out: [String: PcReading] = [:]
        for (key, value) in PcJSON.dict(json["readings"]) ?? [:] {
            guard let r = value as? [String: Any] else { continue }
            out[key] = PcReading(key: key, label: PcJSON.text(r["label"]) ?? key, unit: PcJSON.text(r["unit"]) ?? "",
                                 group: PcJSON.text(r["group"]) ?? "other", estimated: PcJSON.bool(r["estimated"]))
        }
        readings = out
        let kinds = PcJSON.strings(json["widget_kinds"]).compactMap(PcWidgetKind.init(rawValue:))
        self.kinds = kinds.isEmpty ? PcWidgetKind.allCases : kinds
        columns = PcJSON.int(json["columns"]) ?? PcLayout.columns
    }

    /// A fixed reading, or a fan / temperature the PC named itself (`fan.<slug>`, `temp.<slug>`),
    /// resolved the way `reading_info` does on the server.
    func info(_ key: String) -> PcReading? {
        if let r = readings[key] { return r }
        if key == "temp.*" { return PcReading(key: key, label: "All temperatures", unit: "°C", group: "temps", estimated: false) }
        if key == "fan.*" { return PcReading(key: key, label: "All fans", unit: "rpm", group: "cooling", estimated: false) }
        guard let dot = key.firstIndex(of: "."), key.range(of: #"^(fan|temp)\.[a-z0-9_]{1,40}$"#,
                                                           options: .regularExpression) != nil else { return nil }
        let kind = String(key[..<dot])
        let slug = Self.words(String(key[key.index(after: dot)...]))
        return PcReading(key: key, label: slug, unit: kind == "fan" ? "rpm" : "°C",
                         group: kind == "fan" ? "cooling" : "temps", estimated: false)
    }

    /// A sensor slug in words, the server's rule (underscores → spaces, Title Case) with hardware
    /// acronyms kept in capitals: "cpu_fan" → "CPU Fan", "nvme_ssd" → "NVMe SSD", "vrm_mos" → "VRM MOS".
    static func words(_ slug: String) -> String {
        let special: [String: String] = ["cpu": "CPU", "gpu": "GPU", "vrm": "VRM", "mos": "MOS", "ssd": "SSD", "hdd": "HDD",
                                         "nvme": "NVMe", "pch": "PCH", "ram": "RAM", "dimm": "DIMM", "aio": "AIO",
                                         "soc": "SoC", "m2": "M.2", "usb": "USB", "pcie": "PCIe", "ddr5": "DDR5", "ddr4": "DDR4"]
        return slug.split(separator: "_").map { w in special[w.lowercased()] ?? w.capitalized }.joined(separator: " ")
    }

    /// Groups in the order the library lists them.
    static let groupOrder = ["cpu", "gpu", "frames", "memory", "disk", "network", "power", "cooling", "temps"]

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "cpu": return "CPU"
        case "gpu": return "GPU"
        case "frames": return "Frames"
        case "memory": return "Memory"
        case "disk": return "Disk"
        case "network": return "Network"
        case "power": return "Power"
        case "cooling": return "Fans"
        case "temps": return "Temperatures"
        default: return group.capitalized
        }
    }

    /// Every reading worth offering: the fixed catalog plus the PC's own fans and
    /// temperatures from its latest sample, grouped and in order.
    func grouped(extraKeys: [String] = []) -> [PcReadingGroup] {
        var all = Array(readings.values)
        for key in ["temp.*", "fan.*"] + extraKeys where readings[key] == nil {
            if let r = info(key) { all.append(r) }
        }
        let byGroup = Dictionary(grouping: all, by: \.group)
        let order = Self.groupOrder + byGroup.keys.filter { !Self.groupOrder.contains($0) }.sorted()
        return order.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            return PcReadingGroup(group: g, readings: list.sorted { $0.key < $1.key })
        }
    }
}

struct PcReadingGroup: Identifiable {
    let group: String
    let readings: [PcReading]
    var id: String { group }
}

// MARK: - Live and summary

/// `GET /api/pc-stats/live?device_id=` → `{device_id, name, online, at, sample: {r, game}, estimated}`.
struct PcLive: Equatable {
    var deviceId: String?
    var name: String
    var online: Bool
    var at: Date?
    var values: [String: Double]
    var game: String?
    /// The game's friendly name from the server ("Call of Duty"), when it sent one.
    var gameName: String? = nil
    var estimated: Set<String>
    /// The server had a sample (possibly old) for this PC.
    var hasSample: Bool

    /// What to call the running game: the server's name, else the exe without ".exe".
    var displayGame: String? { game.map { PcGames.name(exe: $0, known: gameName) } }

    static let none = PcLive(deviceId: nil, name: "", online: false, at: nil, values: [:], game: nil,
                             estimated: [], hasSample: false)

    init(deviceId: String?, name: String, online: Bool, at: Date?, values: [String: Double], game: String?,
         gameName: String? = nil, estimated: Set<String>, hasSample: Bool) {
        self.deviceId = deviceId
        self.name = name
        self.online = online
        self.at = at
        self.values = values
        self.game = game
        self.gameName = gameName
        self.estimated = estimated
        self.hasSample = hasSample
    }

    init(json: [String: Any]) {
        deviceId = PcJSON.text(json["device_id"])
        name = PcJSON.text(json["name"]) ?? ""
        online = PcJSON.bool(json["online"])
        at = PcJSON.date(json["at"])
        let sample = PcJSON.dict(json["sample"])
        hasSample = sample != nil
        var values: [String: Double] = [:]
        for (k, v) in PcJSON.dict(sample?["r"]) ?? [:] {
            if let d = PcJSON.double(v) { values[k] = d }
        }
        self.values = values
        let game = PcJSON.text(sample?["game"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.game = (game?.isEmpty ?? true) ? nil : game
        gameName = PcJSON.text(json["game_name"])
        estimated = Set(PcJSON.strings(json["estimated"]))
    }
}

/// `GET /api/pc-stats/summary?device_id=` →
/// `{device_id, online, at, cpu, gpu, cpu_temp, gpu_temp, hottest, watts}`.
struct PcSummary: Equatable {
    var online: Bool
    var at: Date?
    var cpu: Double?
    var gpu: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var hottest: Double?
    var watts: Double?
    /// The running game's exe and friendly name.
    var game: String? = nil
    var gameName: String? = nil

    var displayGame: String? { game.map { PcGames.name(exe: $0, known: gameName) } }

    init(online: Bool, at: Date?, cpu: Double?, gpu: Double?, cpuTemp: Double? = nil, gpuTemp: Double? = nil,
         hottest: Double?, watts: Double?) {
        self.online = online
        self.at = at
        self.cpu = cpu
        self.gpu = gpu
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.hottest = hottest
        self.watts = watts
    }

    init(json: [String: Any]) {
        online = PcJSON.bool(json["online"])
        at = PcJSON.date(json["at"])
        cpu = PcJSON.double(json["cpu"])
        gpu = PcJSON.double(json["gpu"])
        cpuTemp = PcJSON.double(json["cpu_temp"])
        gpuTemp = PcJSON.double(json["gpu_temp"])
        hottest = PcJSON.double(json["hottest"])
        watts = PcJSON.double(json["watts"])
        let g = PcJSON.text(json["game"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        game = (g?.isEmpty ?? true) ? nil : g
        gameName = PcJSON.text(json["game_name"])
    }

    /// One of the card's numbers: a usage with its temperature beside it at the same size.
    struct Metric: Equatable {
        let label: String
        let value: String
        /// "72°C", or nil when the PC didn't report one.
        let temp: String?
    }

    /// The PC card's numbers (owner: temps big right next to usage): "CPU 38% · 72°C",
    /// "GPU 96% · 67°C", then the watts. An older server without per-part temperatures
    /// gets the hottest one as its own number.
    var cardMetrics: [Metric] {
        func temp(_ v: Double?) -> String? { v.map { PcFormat.number($0, unit: "°C") + "°" } }
        var out = [Metric(label: "CPU", value: PcFormat.compact(cpu, unit: "%"), temp: temp(cpuTemp)),
                   Metric(label: "GPU", value: PcFormat.compact(gpu, unit: "%"), temp: temp(gpuTemp))]
        if cpuTemp == nil, gpuTemp == nil, let h = hottest {
            out.append(Metric(label: "Hottest", value: PcFormat.compact(h, unit: "°C"), temp: nil))
        }
        out.append(Metric(label: "PC (est.)", value: PcFormat.compact(watts, unit: "W"), temp: nil))
        return out
    }
}

// MARK: - Games

/// A game the PC has seen: its friendly name and its Windows icon (PNG bytes).
struct PcGame: Equatable {
    let name: String
    let icon: Data?
}

/// `GET /api/pc-stats/games` → `{games: {exe: {name, icon: "data:image/png;base64,…" | null}}}`.
enum PcGames {
    static func parse(_ json: [String: Any]) -> [String: PcGame] {
        var out: [String: PcGame] = [:]
        for (exe, v) in PcJSON.dict(json["games"]) ?? [:] {
            guard let g = v as? [String: Any] else { continue }
            out[exe.lowercased()] = PcGame(name: PcJSON.text(g["name"]) ?? name(exe: exe, known: nil),
                                           icon: decodeDataURL(g["icon"] as? String))
        }
        return out
    }

    /// The bytes of a `data:image/…;base64,…` URL; nil for anything else or bad base64.
    static func decodeDataURL(_ s: String?) -> Data? {
        guard let s, s.hasPrefix("data:image/"), let comma = s.range(of: ";base64,") else { return nil }
        let b64 = String(s[comma.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b64.isEmpty, let data = Data(base64Encoded: b64), !data.isEmpty else {
            return nil
        }
        return data
    }

    /// A game's name: the one the server knows, else the exe without ".exe" ("cod.exe" → "cod").
    static func name(exe: String, known: String?) -> String {
        if let k = known?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        var e = exe.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = e.lastIndex(where: { $0 == "\\" || $0 == "/" }) { e = String(e[e.index(after: slash)...]) }
        if e.lowercased().hasSuffix(".exe") { e = String(e.dropLast(4)) }
        return e.isEmpty ? "Game" : e
    }
}

// MARK: - Dashboards

enum PcWidgetKind: String, CaseIterable, Identifiable {
    case hero, number, chart, bars, ring, sparkline, stats, text, session, moments
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero: return "Hero"
        case .number: return "Number"
        case .chart: return "Chart"
        case .bars: return "Bars"
        case .ring: return "Ring"
        case .sparkline: return "Sparkline"
        case .stats: return "Stats"
        case .text: return "Text"
        case .session: return "Game session"
        case .moments: return "Marked moments"
        }
    }

    var blurb: String {
        switch self {
        case .hero: return "One big number with a chart and a meta row"
        case .number: return "A single reading"
        case .chart: return "One or more readings over time"
        case .bars: return "A breakdown, like power by part"
        case .ring: return "A reading as a gauge"
        case .sparkline: return "A reading with a small trend line"
        case .stats: return "A grid of numbers, each with a tiny trend"
        case .text: return "A heading or note"
        case .session: return "The latest game session"
        case .moments: return "Problems marked in the last day"
        }
    }

    var symbol: String {
        switch self {
        case .hero: return "textformat.size.larger"
        case .number: return "number"
        case .chart: return "chart.xyaxis.line"
        case .bars: return "chart.bar.doc.horizontal"
        case .ring: return "gauge.with.dots.needle.67percent"
        case .sparkline: return "waveform.path.ecg"
        case .stats: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .session: return "gamecontroller"
        case .moments: return "exclamationmark.triangle"
        }
    }

    /// Whether the widget is bound to readings (text, session and moments aren't).
    var takesReadings: Bool { ![.text, .session, .moments].contains(self) }
    /// Whether it draws a time series.
    var hasChart: Bool { [.hero, .chart, .sparkline, .number, .stats].contains(self) }
    /// Whether it shows a meta row.
    var hasMeta: Bool { [.hero, .bars].contains(self) }
    /// Whether it uses more than its first reading.
    var multiReading: Bool { [.chart, .bars, .stats].contains(self) }

    /// The grid size a new widget of this kind gets (12 columns).
    var defaultSize: (w: Int, h: Int) {
        switch self {
        case .hero: return (6, 4)
        case .number: return (3, 2)
        case .chart: return (6, 4)
        case .bars: return (4, 4)
        case .ring: return (3, 2)
        case .sparkline: return (3, 2)
        case .stats: return (6, 4)
        case .text: return (4, 1)
        case .session: return (6, 3)
        case .moments: return (12, 2)
        }
    }
}

enum PcChartType: String, CaseIterable, Identifiable {
    case area, line, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A widget's `style` (keys ⊆ chart, color, warn, crit, window, decimals, meta, label, unit).
struct PcWidgetStyle: Equatable {
    var chart: PcChartType?
    var color: String?
    var warn: Double?
    var crit: Double?
    var window: Int?
    var decimals: Int?
    var meta: [String] = []
    var label: String?
    var unit: String?

    init(chart: PcChartType? = nil, color: String? = nil, warn: Double? = nil, crit: Double? = nil,
         window: Int? = nil, decimals: Int? = nil, meta: [String] = [], label: String? = nil, unit: String? = nil) {
        self.chart = chart
        self.color = color
        self.warn = warn
        self.crit = crit
        self.window = window
        self.decimals = decimals
        self.meta = meta
        self.label = label
        self.unit = unit
    }

    init(json: [String: Any]) {
        chart = PcJSON.text(json["chart"]).flatMap(PcChartType.init(rawValue:))
        color = PcJSON.text(json["color"])
        warn = PcJSON.double(json["warn"])
        crit = PcJSON.double(json["crit"])
        window = PcJSON.int(json["window"])
        decimals = PcJSON.int(json["decimals"])
        meta = PcJSON.strings(json["meta"])
        label = json["label"] as? String
        unit = json["unit"] as? String
    }

    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let chart { out["chart"] = chart.rawValue }
        if let color { out["color"] = color }
        if let warn { out["warn"] = warn }
        if let crit { out["crit"] = crit }
        if let window { out["window"] = window }
        if let decimals { out["decimals"] = decimals }
        if !meta.isEmpty { out["meta"] = meta }
        if let label, !label.isEmpty { out["label"] = label }
        if let unit, !unit.isEmpty { out["unit"] = unit }
        return out
    }
}

struct PcWidget: Identifiable, Equatable {
    var id: String
    var kind: PcWidgetKind
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var readings: [String]
    var style: PcWidgetStyle

    init(id: String, kind: PcWidgetKind, x: Int = 0, y: Int = 0, w: Int, h: Int,
         readings: [String] = [], style: PcWidgetStyle = PcWidgetStyle()) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.readings = readings
        self.style = style
    }

    init?(json: [String: Any]) {
        guard let id = PcJSON.text(json["id"]),
              let kind = PcJSON.text(json["kind"]).flatMap(PcWidgetKind.init(rawValue:)) else { return nil }
        self.id = id
        self.kind = kind
        x = PcJSON.int(json["x"]) ?? 0
        y = PcJSON.int(json["y"]) ?? 0
        w = max(1, PcJSON.int(json["w"]) ?? kind.defaultSize.w)
        h = max(1, PcJSON.int(json["h"]) ?? kind.defaultSize.h)
        readings = PcJSON.strings(json["readings"])
        style = PcWidgetStyle(json: PcJSON.dict(json["style"]) ?? [:])
    }

    var json: [String: Any] {
        ["id": id, "kind": kind.rawValue, "x": x, "y": y, "w": w, "h": h, "readings": readings, "style": style.json]
    }

    /// The reading the widget is about (its first).
    var primary: String? { readings.first }
}

struct PcDashboard: Identifiable, Equatable {
    var id: String
    var name: String
    /// nil, or "game" (shown on the PC window while a game runs).
    var auto: String?
    var widgets: [PcWidget]
    /// The server's revision; nil for one not saved yet.
    var rev: Int?

    init(id: String, name: String, auto: String? = nil, widgets: [PcWidget] = [], rev: Int? = nil) {
        self.id = id
        self.name = name
        self.auto = auto
        self.widgets = widgets
        self.rev = rev
    }

    init?(json: [String: Any]) {
        guard let id = PcJSON.text(json["id"]) else { return nil }
        self.id = id
        name = PcJSON.text(json["name"]) ?? id
        auto = PcJSON.text(json["auto"])
        widgets = PcJSON.maps(json["widgets"]).compactMap(PcWidget.init(json:))
        rev = PcJSON.int(json["rev"])
    }

    /// The body PUT sends (`rev` travels beside it).
    var json: [String: Any] {
        ["id": id, "name": name, "auto": auto as Any? ?? NSNull(), "widgets": widgets.map(\.json)]
    }

    static func list(_ json: [String: Any]) -> [PcDashboard] {
        PcJSON.maps(json["dashboards"]).compactMap(PcDashboard.init(json:))
    }

    /// A new dashboard's id from its name: "My Racing!" → "my-racing-4f2a".
    static func newID(name: String, taken: Set<String>, suffix: () -> String = { String(UUID().uuidString.prefix(4)).lowercased() }) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.last == "-") { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = String((slug.isEmpty ? "dashboard" : slug).prefix(32))
        var id = base
        while taken.contains(id) { id = "\(base)-\(suffix())" }
        return id
    }
}

// MARK: - History

struct PcPoint: Equatable {
    let t: Double
    let avg: Double
    var min: Double
    var max: Double

    init(t: Double, avg: Double, min: Double? = nil, max: Double? = nil) {
        self.t = t
        self.avg = avg
        self.min = min ?? avg
        self.max = max ?? avg
    }

    /// `[[t, avg, min, max], …]`.
    static func list(_ json: [String: Any]) -> [PcPoint] {
        ((json["points"] as? [Any]) ?? []).compactMap { row in
            guard let a = row as? [Any], a.count >= 2, let t = PcJSON.double(a[0]), let avg = PcJSON.double(a[1]) else {
                return nil
            }
            return PcPoint(t: t, avg: avg, min: a.count > 2 ? PcJSON.double(a[2]) : nil,
                           max: a.count > 3 ? PcJSON.double(a[3]) : nil)
        }
    }
}

struct PcSession: Identifiable, Equatable, Hashable {
    let id: String
    let exe: String
    let title: String
    let start: Date
    let end: Date?
    let fpsAvg: Double?
    let fpsLow1: Double?
    let cpuTempMax: Double?
    let gpuTempMax: Double?
    let energyWh: Double?
    let wattsAvg: Double?
    let wattsMax: Double?
    let throttleS: Double?

    init?(json: [String: Any]) {
        guard let id = PcJSON.text(json["id"]), let start = PcJSON.date(json["start"]) else { return nil }
        self.id = id
        exe = PcJSON.text(json["exe"]) ?? ""
        title = PcJSON.text(json["title"]) ?? ""
        self.start = start
        end = PcJSON.date(json["end"])
        fpsAvg = PcJSON.double(json["fps_avg"])
        fpsLow1 = PcJSON.double(json["fps_low1"])
        cpuTempMax = PcJSON.double(json["cpu_temp_max"])
        gpuTempMax = PcJSON.double(json["gpu_temp_max"])
        energyWh = PcJSON.double(json["energy_wh"])
        wattsAvg = PcJSON.double(json["watts_avg"])
        wattsMax = PcJSON.double(json["watts_max"])
        throttleS = PcJSON.double(json["throttle_s"])
    }

    /// The game's name: its window title, else the exe without ".exe".
    var name: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return PcGames.name(exe: exe, known: nil)
    }

    /// Its name as the games map knows it ("Call of Duty"), else `name`.
    func name(games: [String: PcGame]) -> String {
        if let n = games[exe.lowercased()]?.name ?? games[exe]?.name, !n.isEmpty { return n }
        return name
    }

    func duration(now: Date = Date()) -> TimeInterval { (end ?? now).timeIntervalSince(start) }
}

struct PcMoment: Identifiable, Equatable {
    let id: String
    let t: Date
    let key: String
    let value: Double?
    let threshold: Double?
    let kind: String
    let durationS: Double?
    let label: String

    init?(json: [String: Any]) {
        guard let id = PcJSON.text(json["id"]), let t = PcJSON.date(json["t"]) else { return nil }
        self.id = id
        self.t = t
        key = PcJSON.text(json["key"]) ?? ""
        value = PcJSON.double(json["value"])
        threshold = PcJSON.double(json["threshold"])
        kind = PcJSON.text(json["kind"]) ?? ""
        durationS = PcJSON.double(json["duration_s"])
        label = PcJSON.text(json["label"]) ?? ""
    }
}

struct PcEnergyBucket: Identifiable, Equatable {
    let start: Date
    let kwh: Double
    let cost: Double
    var id: Double { start.timeIntervalSince1970 }
}

/// `GET /api/pc-stats/energy?period=` → `{buckets, price, currency, period}`.
struct PcEnergy: Equatable {
    var buckets: [PcEnergyBucket]
    var price: Double
    var currency: String

    init(json: [String: Any]) {
        buckets = PcJSON.maps(json["buckets"]).compactMap { b in
            guard let s = PcJSON.date(b["start"]) else { return nil }
            return PcEnergyBucket(start: s, kwh: PcJSON.double(b["kwh"]) ?? 0, cost: PcJSON.double(b["cost"]) ?? 0)
        }
        price = PcJSON.double(json["price"]) ?? 0
        currency = PcJSON.text(json["currency"]) ?? "USD"
    }

    var totalKwh: Double { buckets.reduce(0) { $0 + $1.kwh } }
    var totalCost: Double { buckets.reduce(0) { $0 + $1.cost } }
}

enum PcEnergyPeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The page's time range: Live (each widget's own window, filled second by second),
/// the last hour, or the last day.
enum PcRange: String, CaseIterable, Identifiable {
    case live, hour, day
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live"
        case .hour: return "1 h"
        case .day: return "24 h"
        }
    }

    /// Seconds a widget's chart spans in this range.
    func window(for widget: PcWidget) -> Int {
        switch self {
        case .live: return widget.style.window ?? PcLayout.liveWindow
        case .hour: return 3600
        case .day: return 86_400
        }
    }
}

// MARK: - Layout

/// The grid ↔ one column rules.
enum PcLayout {
    static let columns = 12
    /// A Live chart's span when the widget doesn't set its own window.
    static let liveWindow = 300

    /// The phone's order: top to bottom, then left to right (stable for ties).
    static func reflow(_ widgets: [PcWidget]) -> [PcWidget] {
        widgets.enumerated().sorted { a, b in
            (a.element.y, a.element.x, a.offset) < (b.element.y, b.element.x, b.offset)
        }.map(\.element)
    }

    /// `_free_slot` in tools/pc_stats_tool.py: the first (x, y), row by row, where a w×h widget
    /// fits without overlapping. `after` keeps the scan at or past a position in reading order
    /// so widgets placed one after another stay in that order.
    static func freeSlot(_ placed: [PcWidget], w: Int, h: Int, after: (x: Int, y: Int)? = nil) -> (x: Int, y: Int) {
        let w = max(1, min(columns, w))
        let h = max(1, h)
        var taken = Set<Int>()
        for p in placed {
            for cx in p.x..<(p.x + p.w) { for cy in p.y..<(p.y + p.h) { taken.insert(cy * columns + cx) } }
        }
        func fits(_ x: Int, _ y: Int) -> Bool {
            for cy in y..<(y + h) { for cx in x..<(x + w) where taken.contains(cy * columns + cx) { return false } }
            return true
        }
        for y in (after?.y ?? 0)..<200 {
            for x in 0...(columns - w) {
                if let a = after, y == a.y, x < a.x { continue }
                if fits(x, y) { return (x, y) }
            }
        }
        return (0, 200)
    }

    /// Puts widgets back on the grid in the order given, each keeping its own w/h, each at the
    /// first free slot from the previous one on. The result reflows to the same order.
    static func place(_ ordered: [PcWidget]) -> [PcWidget] {
        var placed: [PcWidget] = []
        var cursor: (x: Int, y: Int)?
        for var w in ordered {
            w.w = max(1, min(columns, w.w))
            let slot = freeSlot(placed, w: w.w, h: w.h, after: cursor)
            w.x = slot.x
            w.y = slot.y
            placed.append(w)
            cursor = slot
        }
        return placed
    }

    /// What Save writes: the grid as it was when nothing moved (new widgets go into the first
    /// free slot after the last one), re-placed in the new order when he reordered.
    static func commit(original: [PcWidget], edited: [PcWidget]) -> [PcWidget] {
        let originalIDs = Set(original.map(\.id))
        let kept = edited.filter { originalIDs.contains($0.id) }
        let keptOrder = kept.map(\.id)
        let gridOrder = reflow(original).map(\.id).filter { keptOrder.contains($0) }
        guard keptOrder == gridOrder else { return place(edited) }
        // Same order: keep every existing widget's position (its settings may have changed).
        let positions = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        var placed: [PcWidget] = kept.map { w in
            var w = w
            if let p = positions[w.id] { w.x = p.x; w.y = p.y; w.w = p.w; w.h = p.h }
            return w
        }
        var cursor: (x: Int, y: Int)? = reflow(placed).last.map { ($0.x, $0.y) }
        var out: [PcWidget] = []
        var keptIterator = placed.makeIterator()
        for w in edited {
            if originalIDs.contains(w.id) {
                if let next = keptIterator.next() { out.append(next) }
            } else {
                var n = w
                n.w = max(1, min(columns, n.w))
                let slot = freeSlot(placed, w: n.w, h: n.h, after: cursor)
                n.x = slot.x
                n.y = slot.y
                placed.append(n)
                cursor = slot
                out.append(n)
            }
        }
        return out
    }

    /// A new widget id unique in the dashboard: "gpu-load", "gpu-load-2", …
    static func newWidgetID(kind: PcWidgetKind, reading: String?, taken: Set<String>) -> String {
        let base = (reading ?? kind.rawValue).replacingOccurrences(of: ".", with: "-")
        var id = base
        var n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// The phone column: full-width cards, except that consecutive small tiles (number,
    /// ring, sparkline no wider than a third of the grid) sit two to a row. Order is kept.
    static func rows(_ ordered: [PcWidget]) -> [[PcWidget]] {
        var rows: [[PcWidget]] = []
        var pending: PcWidget?
        func small(_ w: PcWidget) -> Bool { [.number, .ring, .sparkline].contains(w.kind) && w.w <= 4 }
        // A small tile stacked right under another on the grid (same column, touching) is its
        // partner on the phone even when a bigger widget comes between them in reading order.
        var ordered = ordered
        var i = 0
        while i < ordered.count {
            let a = ordered[i]
            if small(a), i + 1 < ordered.count, !small(ordered[i + 1]),
               let j = ordered.indices.first(where: { $0 > i + 1 && small(ordered[$0]) && ordered[$0].x == a.x
                                                       && ordered[$0].y == a.y + a.h }) {
                let b = ordered.remove(at: j)
                ordered.insert(b, at: i + 1)
            }
            i += 1
        }
        for w in ordered {
            if small(w) {
                if let p = pending { rows.append([p, w]); pending = nil } else { pending = w }
            } else {
                if let p = pending { rows.append([p]); pending = nil }
                rows.append([w])
            }
        }
        if let p = pending { rows.append([p]) }
        return rows
    }
}

// MARK: - Words and numbers

/// A reading as the phone shows it.
enum PcValue: Equatable {
    case value(String, unit: String)
    /// Missing from the sample — never drawn as 0.
    case unavailable(String)

    var isAvailable: Bool { if case .value = self { return true } else { return false } }
}

enum PcFormat {
    /// Default decimals by unit.
    static func decimals(unit: String, value: Double) -> Int {
        switch unit {
        case "GB", "MB/s", "ms": return value >= 100 ? 0 : 1
        default: return 0
        }
    }

    /// "38", "21.4", "1 640" — grouping off so the digits stay tabular.
    static func number(_ v: Double, unit: String, decimals: Int? = nil) -> String {
        let d = max(0, min(3, decimals ?? Self.decimals(unit: unit, value: abs(v))))
        let rounded = (v * pow(10, Double(d))).rounded() / pow(10, Double(d))
        return String(format: "%.\(d)f", rounded == 0 ? 0 : rounded)
    }

    /// The unit as it's written after a number.
    static func unitLabel(_ unit: String) -> String {
        switch unit {
        case "°C": return "°"
        default: return unit
        }
    }

    /// Why a reading is missing, in words.
    static func unavailableReason(_ key: String, live: PcLive) -> String {
        if !live.hasSample { return "No data yet" }
        if key == "cpu.temp" || key == "cpu.power" || key.hasPrefix("fan.") || key.hasPrefix("temp.") {
            return "Needs the sensor driver"
        }
        if key == "fps" || key == "fps.low1" || key == "frametime" { return live.game == nil ? "No game running" : "Unavailable" }
        return "Unavailable"
    }

    /// One reading from the latest sample: its number and unit, or "unavailable" with why.
    static func value(_ key: String?, live: PcLive, catalog: PcCatalog, style: PcWidgetStyle = PcWidgetStyle()) -> PcValue {
        guard let key else { return .unavailable("No reading chosen") }
        guard let v = live.values[key] else { return .unavailable(unavailableReason(key, live: live)) }
        let unit = style.unit ?? catalog.info(key)?.unit ?? ""
        return .value(number(v, unit: unit, decimals: style.decimals), unit: unitLabel(unit))
    }

    /// "38%", "72°", "462 W", or "—" for a missing number (the card's four numbers).
    static func compact(_ v: Double?, unit: String) -> String {
        guard let v else { return "—" }
        let n = number(v, unit: unit)
        switch unit {
        case "%", "°C": return n + unitLabel(unit)
        default: return "\(n) \(unit)"
        }
    }

    /// Whether to badge a reading "est.": the PC said so, or the catalog marks it estimated.
    static func isEstimated(_ key: String?, live: PcLive, catalog: PcCatalog) -> Bool {
        guard let key else { return false }
        return live.estimated.contains(key) || (catalog.info(key)?.estimated ?? false)
    }

    /// The tone a value takes against the widget's thresholds.
    enum Tone: Equatable { case normal, warn, crit }

    static func tone(_ v: Double?, style: PcWidgetStyle) -> Tone {
        guard let v else { return .normal }
        if let c = style.crit, v >= c { return .crit }
        if let w = style.warn, v >= w { return .warn }
        return .normal
    }

    // Owner, 2026-11-15: "temps need to be bigger right next to usage percentage".

    static func isTemperature(_ key: String) -> Bool { key.hasSuffix(".temp") || key.hasPrefix("temp.") }

    /// A load hero's temperature (from its meta row), drawn at the hero size beside the usage:
    /// "96% · 67°C". nil for any other widget.
    static func heroTemperature(_ w: PcWidget) -> String? {
        guard w.kind == .hero, let p = w.primary, p.hasSuffix(".load") else { return nil }
        return w.style.meta.first(where: isTemperature)
    }

    /// The meta row once the big temperature has been lifted out of it.
    static func heroMeta(_ w: PcWidget) -> [String] {
        guard let t = heroTemperature(w) else { return w.style.meta }
        return w.style.meta.filter { $0 != t }
    }

    /// On a load hero the widget's warn/crit are the temperature's (GPU 85/95, CPU 90/100
    /// when the widget sets none); the usage itself isn't tinted.
    static func heroTemperatureStyle(_ w: PcWidget, key: String) -> PcWidgetStyle {
        let defaults: (Double, Double) = key.hasPrefix("cpu.") ? (90, 100) : (85, 95)
        return PcWidgetStyle(warn: w.style.warn ?? defaults.0, crit: w.style.crit ?? defaults.1,
                             decimals: w.style.decimals)
    }

    /// The temperature as the hero writes it: the number, "°C" small after it.
    static func heroTemperatureValue(_ key: String, live: PcLive, decimals: Int? = nil) -> PcValue {
        guard let v = live.values[key] else { return .unavailable(unavailableReason(key, live: live)) }
        return .value(number(v, unit: "°C", decimals: decimals), unit: "°")
    }

    /// Readings with the wildcards "temp.*" / "fan.*" replaced by every temp.<slug> / fan.<slug>
    /// in the live sample, sorted; a key named twice appears once.
    static func expand(_ readings: [String], live: PcLive) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ k: String) { if seen.insert(k).inserted { out.append(k) } }
        let explicit = Set(readings.filter { !$0.hasSuffix(".*") })
        for r in readings {
            if r == "temp.*" || r == "fan.*" {
                let prefix = String(r.dropLast())   // "temp." / "fan."
                for k in live.values.keys.sorted() where k.hasPrefix(prefix) && !explicit.contains(k) { add(k) }
            } else {
                add(r)
            }
        }
        return out
    }

    /// One cell of a stats tile: its label, the value ("72°" for a temperature, the unit inline),
    /// and the small unit after it ("MHz"); "—" when the PC didn't report it, never 0.
    struct StatsCell: Equatable {
        let label: String
        let value: String
        let unit: String
    }

    static func statsCell(_ key: String, live: PcLive, catalog: PcCatalog, style: PcWidgetStyle = PcWidgetStyle()) -> StatsCell {
        let label = catalog.info(key)?.label ?? shortLabel(key, catalog: catalog)
        guard let v = live.values[key] else { return StatsCell(label: label, value: "—", unit: "") }
        let unit = style.unit ?? catalog.info(key)?.unit ?? ""
        let n = number(v, unit: unit, decimals: style.decimals)
        if unit == "°C" { return StatsCell(label: label, value: n + "°", unit: "") }
        return StatsCell(label: label, value: n, unit: unit)
    }

    /// A row's name in a bar list: short words for the fixed readings, the catalog label else.
    static func shortLabel(_ key: String, catalog: PcCatalog) -> String {
        let names: [String: String] = [
            "power.gpu": "GPU", "power.cpu": "CPU", "power.ram": "RAM", "power.disk": "Disk", "power.net": "Network",
            "power.total": "PC (est.)", "ram.used": "RAM", "ram.commit": "Commit", "gpu.vram_used": "VRAM",
            "disk.used": "Disk C:", "gpu.fan": "GPU fan", "cpu.load": "CPU", "gpu.load": "GPU", "cpu.temp": "CPU",
            "gpu.temp": "GPU", "gpu.hotspot": "Hotspot", "disk.read": "Read", "disk.write": "Write",
            "net.down": "Down", "net.up": "Up", "cpu.power": "CPU", "gpu.power": "GPU",
        ]
        return names[key] ?? catalog.info(key)?.label ?? key
    }

    /// How full a bar is (0…1): a share of its total where one is known, else of the row's peers.
    static func barFraction(_ key: String, values: [String: Double], peers: [String], catalog: PcCatalog,
                            style: PcWidgetStyle = PcWidgetStyle()) -> Double {
        guard let v = values[key] else { return 0 }
        let unit = catalog.info(key)?.unit ?? ""
        let peerMax = peers.compactMap { values[$0] }.max() ?? v
        let whole: Double
        switch (key, unit) {
        case ("ram.used", _), ("ram.commit", _): whole = values["ram.total"] ?? peerMax
        case ("gpu.vram_used", _): whole = values["gpu.vram_total"] ?? peerMax
        case (_, "%"): whole = 100
        case (_, "°C"): whole = style.crit ?? 100
        case (_, "W"): whole = key == "power.total" ? peerMax : (values["power.total"] ?? peers.compactMap { values[$0] }.reduce(0, +))
        case (_, "rpm"): whole = Swift.max(3000, peerMax)
        default: whole = peerMax
        }
        guard whole > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, v / whole))
    }

    /// A bar row's value: "21.4 GB" or, for a share of RAM/VRAM, "67%".
    static func barValue(_ key: String, values: [String: Double], catalog: PcCatalog, style: PcWidgetStyle) -> String {
        guard let v = values[key] else { return "—" }
        if key == "gpu.vram_used", let t = values["gpu.vram_total"], t > 0 { return "\(Int((v / t * 100).rounded()))%" }
        if key == "ram.used", let t = values["ram.total"], t > 0 { return "\(Int((v / t * 100).rounded()))%" }
        let unit = catalog.info(key)?.unit ?? ""
        return compact(v, unit: unit)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func money(_ v: Double, currency: String) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currency.isEmpty ? "USD" : currency)
        return v.formatted(v < 1 ? style.precision(.fractionLength(2...3)) : style.precision(.fractionLength(2)))
    }

    static func kwh(_ v: Double) -> String {
        String(format: v < 10 ? "%.2f" : "%.1f", v)
    }
}

/// The PC Stats words, pure for the tests.
enum PcStatsCopy {
    /// "Online", "Playing Call of Duty", "PC offline · last seen 5 min ago", or
    /// "No stats from this PC yet".
    static func status(online: Bool, at: Date?, game: String? = nil, now: Date = Date()) -> String {
        if online { return game.map { "Playing \($0)" } ?? "Online" }
        guard let at else { return "No stats from this PC yet" }
        return "PC offline · last seen \(AgentsMacPowerCopy.ago(at, now: now))"
    }

    /// A window in words: "5 min", "1 h", "24 h".
    static func window(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(max(1, seconds / 60)) min" }
        return "\(seconds / 3600) h"
    }

    static let windows = [60, 300, 900, 3600, 21_600, 86_400]

    static let conflict = "Changed elsewhere — reloaded"
}

// MARK: - Apple look: categories and chart maths
// docs/superpowers/specs/2026-11-15-pc-stats-apple-look.md (owner, 2026-11-15: "very
// professional, Apple feel" — Health / Fitness style).

/// What a reading is about: its SF Symbol and (via `PcLook.metric`) its data colour.
enum PcCategory: String, Equatable {
    case gpu, cpu, frames, power, memory, network, cooling, temps, other

    static func of(_ key: String?) -> PcCategory {
        guard let key else { return .other }
        if key.hasPrefix("gpu.vram") || key.hasPrefix("ram.") || key.hasPrefix("disk.") { return .memory }
        if key.hasPrefix("fan.") || key == "gpu.fan" { return .cooling }
        if key.hasSuffix(".temp") || key.hasPrefix("temp.") || key == "gpu.hotspot" { return .temps }
        if key.hasPrefix("gpu.") { return .gpu }
        if key.hasPrefix("cpu.") { return .cpu }
        if key == "fps" || key.hasPrefix("fps.") || key == "frametime" { return .frames }
        if key.hasPrefix("power.") { return .power }
        if key.hasPrefix("net.") { return .network }
        return .other
    }

    var symbol: String {
        switch self {
        case .gpu: return "display"
        case .cpu: return "cpu"
        case .frames: return "speedometer"
        case .power: return "bolt.fill"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .cooling: return "fan"
        case .temps: return "thermometer.medium"
        case .other: return "chart.xyaxis.line"
        }
    }
}

extension PcCategory {
    /// In a chart with several lines, a part's temperature takes the part's colour (GPU temp vs
    /// CPU temp → GPU vs CPU), so the lines tell apart.
    static func part(_ key: String) -> PcCategory {
        switch key {
        case "gpu.temp", "gpu.hotspot": return .gpu
        case "cpu.temp": return .cpu
        default: return of(key)
        }
    }

    /// Each line's group and strength: its own group's colour, and a second / third line from the
    /// same group at 55 % / 30 %.
    static func seriesShades(_ keys: [String]) -> [(category: PcCategory, opacity: Double)] {
        var seen: [PcCategory: Int] = [:]
        return keys.map { key in
            let c = keys.count > 1 ? part(key) : of(key)
            let n = seen[c, default: 0]
            seen[c] = n + 1
            return (c, [1, 0.55, 0.30][min(n, 2)])
        }
    }
}

enum PcChartMath {
    /// Half-width of the moving average: 5 samples (±2) for a minute-scale series, wider as
    /// the series gets longer so a day or a session reads as a trend, never raw spikes.
    static func smoothingRadius(count: Int) -> Int {
        count <= 150 ? 2 : min(24, max(2, count / 60))
    }

    /// A centred moving average (the edges average what's there). Min/max are kept raw.
    static func smooth(_ pts: [PcPoint], radius: Int? = nil) -> [PcPoint] {
        let r = radius ?? smoothingRadius(count: pts.count)
        guard r > 0, pts.count > 2 else { return pts }
        var prefix = [0.0]
        prefix.reserveCapacity(pts.count + 1)
        for p in pts { prefix.append(prefix[prefix.count - 1] + p.avg) }
        return pts.indices.map { i in
            let lo = max(0, i - r), hi = min(pts.count - 1, i + r)
            let avg = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            return PcPoint(t: pts[i].t, avg: avg, min: pts[i].min, max: pts[i].max)
        }
    }

    /// The p-th percentile (0…1), nearest rank.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let i = Int((Double(sorted.count - 1) * min(1, max(0, p))).rounded())
        return sorted[i]
    }

    /// 0–100 for percentages; else 0 (temperatures: a floor 10° under the lowest, in tens) up to
    /// the 98th percentile × 1.15, so one spike can't flatten the line.
    static func yRange(_ values: [Double], unit: String) -> ClosedRange<Double> {
        if unit == "%" { return 0...100 }
        guard let p98 = percentile(values, 0.98), let lo = values.min() else { return 0...1 }
        let floor = unit == "°C" ? max(0, ((lo - 10) / 10).rounded(.down) * 10) : 0
        let top = p98 * 1.15
        return floor...max(top, floor + 1)
    }

    /// The three gridlines: bottom, middle, top.
    static func gridlines(_ range: ClosedRange<Double>) -> [Double] {
        [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]
    }

    /// "Min 58 · Avg 66 · Max 72" over the window, from the raw averages.
    static func stats(_ pts: [PcPoint]) -> (min: Double, avg: Double, max: Double)? {
        guard !pts.isEmpty else { return nil }
        let v = pts.map(\.avg)
        return (v.min()!, v.reduce(0, +) / Double(v.count), v.max()!)
    }

    static func statLine(_ pts: [PcPoint], unit: String) -> String? {
        guard let s = stats(pts) else { return nil }
        func n(_ x: Double) -> String { PcFormat.number(x, unit: unit) }
        return "Min \(n(s.min)) · Avg \(n(s.avg)) · Max \(n(s.max))"
    }
}
