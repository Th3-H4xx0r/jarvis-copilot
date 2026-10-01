import Foundation

/// The live values widgets bind to: one flat JSON object in the App Group, `area.name` → value.
/// The app's `WidgetDataHub` writes it; the widget only reads it. A design binds a value with
/// `{"src": "health.steps"}`, through the same pipeline (fmt/map/when) as the island designs.
enum WidgetDataFile {
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JarvisShared.appGroupID)?
            .appendingPathComponent("widgets", isDirectory: true)
            .appendingPathComponent("data.json")
    }

    static func read(from url: URL? = url) -> [String: JCJSON] {
        guard let url, let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: JCJSON].self, from: data) else { return [:] }
        return values
    }

    static func write(_ values: [String: JCJSON], to url: URL? = url) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object = values.mapValues(\.plain)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JCJSON {
    /// Back to a JSON-serialisable value.
    var plain: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.plain)
        case .object(let o): return o.mapValues(\.plain)
        }
    }
}

/// Every value the hub publishes, for the builder's data picker and for Jarvis.
enum WidgetDataCatalog {
    enum Kind: String, Codable { case number, text, bool, series }

    struct Entry: Codable, Equatable, Identifiable {
        let key: String
        let label: String
        let area: String
        let kind: Kind
        var unit: String? = nil
        var id: String { key }

        var json: [String: Any] {
            var out: [String: Any] = ["key": key, "label": label, "area": area, "kind": kind.rawValue]
            if let unit { out["unit"] = unit }
            return out
        }
    }

    /// The areas, in the order the picker lists them.
    static let areas: [(key: String, label: String, symbol: String)] = [
        ("health", "Health", "heart.fill"), ("wearables", "Wearables", "circle.circle"),
        ("chat", "Chat & voice", "bubble.left.and.text.bubble.right"), ("coding", "Coding", "chevron.left.forwardslash.chevron.right"),
        ("server", "Server", "server.rack"), ("phone", "Phone", "iphone"), ("time", "Time", "clock"),
    ]

    /// The wearables a design can name, with the words used for them.
    static let wearables: [(key: String, name: String)] = [
        ("ring", "R12 ring"), ("x5ring", "X5 ring"), ("glasses", "Glasses"), ("bottle", "Bottle"),
        ("scale", "Scale"), ("esp32", "ESP32 board"),
    ]

    static let entries: [Entry] = {
        var all: [Entry] = [
            Entry(key: "health.score", label: "Body battery", area: "health", kind: .number),
            Entry(key: "health.band", label: "Body battery band", area: "health", kind: .text),
            Entry(key: "health.sleep_score", label: "Sleep score", area: "health", kind: .number),
            Entry(key: "health.recovery", label: "Recovery score", area: "health", kind: .number),
            Entry(key: "health.activity_score", label: "Activity score", area: "health", kind: .number),
            Entry(key: "health.vitals_score", label: "Vitals score", area: "health", kind: .number),
            Entry(key: "health.analysis", label: "Today's analysis", area: "health", kind: .text),
            Entry(key: "health.steps", label: "Steps today", area: "health", kind: .number, unit: "steps"),
            Entry(key: "health.steps_week", label: "Steps, last 7 days", area: "health", kind: .series, unit: "steps"),
            Entry(key: "health.asleep_minutes", label: "Asleep last night", area: "health", kind: .number, unit: "min"),
            Entry(key: "health.asleep", label: "Asleep last night (h m)", area: "health", kind: .text),
            Entry(key: "health.sleep_week", label: "Sleep, last 7 nights", area: "health", kind: .series, unit: "min"),
            Entry(key: "health.deep_minutes", label: "Deep sleep", area: "health", kind: .number, unit: "min"),
            Entry(key: "health.rem_minutes", label: "REM sleep", area: "health", kind: .number, unit: "min"),
            Entry(key: "health.light_minutes", label: "Light sleep", area: "health", kind: .number, unit: "min"),
            Entry(key: "health.hr_avg", label: "Heart rate today", area: "health", kind: .number, unit: "bpm"),
            Entry(key: "health.hr_week", label: "Heart rate, last 7 days", area: "health", kind: .series, unit: "bpm"),
            Entry(key: "health.hrv", label: "HRV", area: "health", kind: .number, unit: "ms"),
            Entry(key: "health.hrv_week", label: "HRV, last 7 days", area: "health", kind: .series, unit: "ms"),
            Entry(key: "health.spo2", label: "Blood oxygen", area: "health", kind: .number, unit: "%"),
            Entry(key: "health.spo2_week", label: "Blood oxygen, last 7 days", area: "health", kind: .series, unit: "%"),
            Entry(key: "health.stress", label: "Stress", area: "health", kind: .number),
            Entry(key: "health.sleep_debt", label: "Sleep debt", area: "health", kind: .number, unit: "min"),
            Entry(key: "chat.last_reply", label: "Jarvis's last reply", area: "chat", kind: .text),
            Entry(key: "chat.last_title", label: "Last chat's title", area: "chat", kind: .text),
            Entry(key: "chat.last_at", label: "Last chat time", area: "chat", kind: .text),
            Entry(key: "chat.working", label: "Jarvis is answering", area: "chat", kind: .bool),
            Entry(key: "coding.working", label: "Coding sessions working", area: "coding", kind: .number),
            Entry(key: "coding.waiting", label: "Coding sessions waiting on you", area: "coding", kind: .number),
            Entry(key: "coding.total", label: "Coding sessions running", area: "coding", kind: .number),
            Entry(key: "coding.summary", label: "Coding summary", area: "coding", kind: .text),
            Entry(key: "server.connected", label: "Connected to Jarvis", area: "server", kind: .bool),
            Entry(key: "server.status", label: "Server status", area: "server", kind: .text),
            Entry(key: "phone.battery", label: "Phone battery", area: "phone", kind: .number, unit: "%"),
            Entry(key: "phone.charging", label: "Phone charging", area: "phone", kind: .bool),
            Entry(key: "alarm.next", label: "Next alarm or timer", area: "phone", kind: .text),
            Entry(key: "time.updated", label: "Last updated", area: "time", kind: .text),
        ]
        for device in wearables {
            all += [
                Entry(key: "\(device.key).name", label: "\(device.name) name", area: "wearables", kind: .text),
                Entry(key: "\(device.key).connected", label: "\(device.name) connected", area: "wearables", kind: .bool),
                Entry(key: "\(device.key).status", label: "\(device.name) status", area: "wearables", kind: .text),
                Entry(key: "\(device.key).battery", label: "\(device.name) battery", area: "wearables", kind: .number, unit: "%"),
                Entry(key: "\(device.key).keep_alive", label: "\(device.name) keep-alive", area: "wearables", kind: .bool),
            ]
        }
        return all
    }()

    static func entries(area: String) -> [Entry] { entries.filter { $0.area == area } }

    static func entry(_ key: String) -> Entry? { entries.first { $0.key == key } }
}
