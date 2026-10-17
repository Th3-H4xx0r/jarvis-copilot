import Foundation

/// What Settings → Battery usage shows, worked out from the ledger's hours: the battery the
/// phone lost, where the app's time and CPU went, what kept it busy in a pocket, and what woke
/// the radio. Pure, so the arithmetic is tested without a phone.
struct BatteryUsageSummary: Equatable {
    typealias Hour = EnergyLedger.Hour

    /// One row of a ranking.
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String?
        let symbol: String
        /// What the row is ranked by (CPU seconds, or a count).
        let value: Double
        /// `value` against the biggest row's (0–1), for the bar under the title.
        var share: Double = 0
        /// `value` against the whole (0–1), for the percentage.
        var ofTotal: Double = 0
    }

    let hours: [Hour]

    init(hours: [Hour]) {
        self.hours = hours
    }

    /// The hours that overlap `since…`.
    static func within(_ hours: [Hour], since: Date) -> [Hour] {
        hours.filter { $0.end > since }
    }

    // MARK: Headline

    var wall: Double { hours.reduce(0) { $0 + $1.wall } }
    func seconds(_ key: String) -> Double { hours.reduce(0) { $0 + $1.seconds(key) } }
    func cpu(_ key: String) -> Double { hours.reduce(0) { $0 + $1.cpu(key) } }
    func count(_ key: String) -> Int { hours.reduce(0) { $0 + $1.count(key) } }

    var onScreen: Double { seconds("foreground") }
    var inPocket: Double { seconds("background") }
    var keptAlive: Double { seconds("bg.keepalive") }
    var cpuTotal: Double { cpu("foreground") + cpu("background") }

    /// Battery points the phone lost in hours with both ends known and no charging.
    var drained: Double? {
        let known = hours.compactMap(\.drained)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// The phone's drain (points an hour) across hours mostly spent a given way. Phone-wide: it
    /// includes every other app, which is what makes "keepalive on vs off" comparable.
    func drainRate(where share: (Hour) -> Double, atLeast: Double = 0.9) -> Double? {
        let picked = hours.filter { $0.wall >= 1800 && $0.drained != nil && share($0) >= atLeast }
        let span = picked.reduce(0) { $0 + $1.wall } / 3600
        guard span >= 0.5 else { return nil }
        return picked.compactMap(\.drained).reduce(0, +) / span
    }

    static func share(_ key: String) -> (Hour) -> Double {
        { $0.wall > 0 ? $0.seconds(key) / $0.wall : 0 }
    }

    /// In a pocket, the keepalive holding / not holding, on Wi-Fi / cellular; and on screen.
    var pocketDrain: Double? { drainRate(where: Self.share("background")) }
    var pocketDrainKeptAlive: Double? {
        drainRate(where: { Self.share("background")($0) >= 0.9 ? Self.share("bg.keepalive")($0) : 0 })
    }
    var pocketDrainSuspended: Double? {
        drainRate(where: { Self.share("background")($0) >= 0.9 ? 1 - Self.share("bg.keepalive")($0) : 0 })
    }
    var pocketDrainWifi: Double? {
        drainRate(where: { Self.share("background")($0) >= 0.9 ? Self.share("bg.wifi")($0) : 0 }, atLeast: 0.8)
    }
    var pocketDrainCellular: Double? {
        drainRate(where: { Self.share("background")($0) >= 0.9 ? Self.share("bg.cellular")($0) : 0 }, atLeast: 0.8)
    }
    var screenDrain: Double? { drainRate(where: Self.share("foreground"), atLeast: 0.5) }

    // MARK: Rankings

    /// Where the app's CPU went: each place on screen, and the pocket as one row.
    var byPlace: [Item] {
        var cpuBy: [String: Double] = [:]
        var timeBy: [String: Double] = [:]
        for hour in hours {
            for (key, value) in hour.cpu where key.hasPrefix("where.") { cpuBy[key, default: 0] += value }
            for (key, value) in hour.seconds where key.hasPrefix("where.") { timeBy[key, default: 0] += value }
        }
        var items = cpuBy.map { key, value in
            let (title, symbol) = Self.place(String(key.dropFirst("where.".count)))
            return Item(id: key, title: title, detail: "\(Self.duration(timeBy[key] ?? 0)) on screen",
                        symbol: symbol, value: value)
        }
        if inPocket > 0 {
            items.append(Item(id: "pocket", title: "In the background",
                              detail: "\(Self.duration(inPocket)), \(Self.duration(keptAlive)) kept alive",
                              symbol: "moon.fill", value: cpu("background")))
        }
        return Self.ranked(items)
    }

    /// Which kind of work the CPU went on, from the threads that did it.
    var byWork: [Item] {
        var total: [String: Double] = [:]
        for hour in hours { for (name, value) in hour.threads { total[Self.work(name), default: 0] += value } }
        return Self.ranked(total.map { title, value in
            Item(id: title, title: title, detail: Self.workDetail(title), symbol: Self.workSymbol(title), value: value)
        })
    }

    /// What talked to the server, by feature — the live link's frames among them.
    var network: [Item] {
        var requests: [String: Int] = [:]
        var pocket: [String: Int] = [:]
        var bytes: [String: Int] = [:]
        for hour in hours {
            for (key, n) in hour.counts {
                if key.hasPrefix("net.bg.") { pocket[String(key.dropFirst(7)), default: 0] += n }
                else if key.hasPrefix("net.") { requests[String(key.dropFirst(4)), default: 0] += n }
                else if key.hasPrefix("bytes.") { bytes[String(key.dropFirst(6)), default: 0] += n }
            }
        }
        var items = requests.map { feature, n in
            Item(id: feature, title: feature,
                 detail: "\(pocket[feature] ?? 0) in the background · \(Self.size(bytes[feature] ?? 0))",
                 symbol: Self.featureSymbol(feature), value: Double(n))
        }
        let frames = count("bridge.in") + count("bridge.out")
        if frames > 0 {
            items.append(Item(id: "bridge", title: "Live link to Jarvis",
                              detail: "\(count("bridge.in").formatted()) in · \(count("bridge.out").formatted()) out · \(Self.size(count("bridge.out_bytes"))) sent",
                              symbol: "dot.radiowaves.left.and.right", value: Double(frames)))
        }
        return Self.ranked(items)
    }

    /// The screen left showing when the phone went into a pocket, by the CPU it burned there.
    var leftOpen: [Item] {
        var cpuBy: [String: Double] = [:]
        var timeBy: [String: Double] = [:]
        for hour in hours {
            for (key, value) in hour.cpu where key.hasPrefix("left.") { cpuBy[key, default: 0] += value }
            for (key, value) in hour.seconds where key.hasPrefix("left.") { timeBy[key, default: 0] += value }
        }
        return Self.ranked(cpuBy.map { key, value in
            let (title, symbol) = Self.place(String(key.dropFirst("left.".count)))
            return Item(id: key, title: title, detail: "left open \(Self.duration(timeBy[key] ?? 0))",
                        symbol: symbol, value: value)
        })
    }

    /// Who asked to send Jarvis the skill list again, and how often it went out or, unchanged,
    /// stayed home.
    var catalogue: [Item] {
        var sent: [String: Int] = [:]
        var same: [String: Int] = [:]
        for hour in hours {
            for (key, n) in hour.counts {
                if key.hasPrefix("register.sent.") { sent[String(key.dropFirst("register.sent.".count)), default: 0] += n }
                if key.hasPrefix("register.same.") { same[String(key.dropFirst("register.same.".count)), default: 0] += n }
            }
        }
        return Self.ranked(Set(sent.keys).union(same.keys).map { caller in
            Item(id: "register.\(caller)", title: caller,
                 detail: "\((sent[caller] ?? 0).formatted()) sent · \((same[caller] ?? 0).formatted()) unchanged, kept home",
                 symbol: "list.bullet.rectangle", value: Double((sent[caller] ?? 0) + (same[caller] ?? 0)))
        })
    }

    /// How long each wearable held a Bluetooth link, and how much of it in the background.
    var bluetooth: [Item] {
        var total: [String: Double] = [:]
        var pocket: [String: Double] = [:]
        for hour in hours {
            for (key, value) in hour.seconds {
                if key.hasPrefix("link.") { total[String(key.dropFirst(5)), default: 0] += value }
                if key.hasPrefix("bg.link.") { pocket[String(key.dropFirst(8)), default: 0] += value }
            }
        }
        return Self.ranked(total.map { name, value in
            Item(id: "link.\(name)", title: name, detail: "\(Self.duration(pocket[name] ?? 0)) in the background",
                 symbol: "dot.radiowaves.right", value: value)
        })
    }

    /// Each hour's CPU on screen and in a pocket, and the battery it lost — for the chart.
    struct HourBar: Identifiable, Equatable {
        let id: Date
        let start: Date
        let onScreen: Double
        let pocket: Double
        let drained: Double?
    }

    var bars: [HourBar] {
        hours.map { HourBar(id: $0.start, start: $0.start, onScreen: $0.cpu("foreground"),
                            pocket: $0.cpu("background"), drained: $0.drained) }
    }

    // MARK: Names

    static func ranked(_ items: [Item]) -> [Item] {
        let sorted = items.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let top = sorted.first?.value ?? 0
        let total = sorted.reduce(0) { $0 + $1.value }
        return sorted.map { item in
            var item = item
            item.share = top > 0 ? item.value / top : 0
            item.ofTotal = total > 0 ? item.value / total : 0
            return item
        }
    }

    /// "health|Sleep" → ("Health › Sleep", symbol).
    static func place(_ raw: String) -> (String, String) {
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let tab = AppTab(rawValue: parts.first ?? "")
        let tabTitle = tab?.title ?? "App"
        let screen = parts.count > 1 ? parts[1] : ""
        let title = screen.isEmpty || screen == tabTitle ? tabTitle : "\(tabTitle) › \(screen)"
        return (title, tab.map(tabSymbol) ?? "app")
    }

    static func tabSymbol(_ tab: AppTab) -> String {
        switch tab {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .voice: return "waveform"
        case .agents: return "chevron.left.forwardslash.chevron.right"
        case .health: return "heart.fill"
        case .devices: return "applewatch"
        case .more: return "ellipsis.circle.fill"
        }
    }

    /// A thread's name as the work it does.
    static func work(_ thread: String) -> String {
        let t = thread.lowercased()
        if t == "main" { return "App & screens" }
        if t.contains("scenekit") || t.contains("scnview") { return "3D models" }
        if t.contains("swiftui") || t.contains("render") { return "Animations & drawing" }
        if t.contains("auremoteio") || t.contains("audio") { return "Audio (keepalive, voice)" }
        if t.contains("bluetooth") { return "Bluetooth" }
        if t.contains("nsurl") || t.contains("network") || t.contains("cfnetwork") { return "Network" }
        if t.contains("location") { return "Location" }
        if t == "unnamed" { return "Background tasks" }
        return thread
    }

    static func workSymbol(_ title: String) -> String {
        switch title {
        case "App & screens": return "iphone"
        case "Animations & drawing": return "sparkles"
        case "3D models": return "cube.fill"
        case "Audio (keepalive, voice)": return "speaker.wave.2.fill"
        case "Bluetooth": return "dot.radiowaves.right"
        case "Network": return "network"
        case "Location": return "location.fill"
        case "Background tasks": return "gearshape.2.fill"
        default: return "cpu"
        }
    }

    static func workDetail(_ title: String) -> String? {
        switch title {
        case "App & screens": return "The main thread: layout, data, timers"
        case "Animations & drawing": return "SwiftUI's renderer: glass, orbs, charts"
        case "3D models": return "SceneKit wearable and car models"
        case "Audio (keepalive, voice)": return "The silent keepalive and voice turns"
        case "Background tasks": return "Unnamed worker threads"
        default: return nil
        }
    }

    static func featureSymbol(_ feature: String) -> String {
        switch feature {
        case "Health history", "Health uploads", "Health": return "heart.text.square.fill"
        case "Chat": return "bubble.left.fill"
        case "Coding agents": return "chevron.left.forwardslash.chevron.right"
        case "Voice": return "waveform"
        case "Dashcam": return "car.rear.fill"
        case "Commands queue": return "tray.full.fill"
        case "Devices": return "applewatch"
        case "Widgets & island": return "square.grid.2x2.fill"
        case "Door alarm": return "door.left.hand.closed"
        case "Car": return "car.fill"
        case "Battery reports": return "battery.75percent"
        default: return "network"
        }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        let h = Int(seconds / 3600)
        let m = Int((seconds - Double(h) * 3600) / 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
