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

    /// A wearable command that reports what it's doing (`WearableDevice.commandState`), as live
    /// values: `<device>.<command without its prefix>` — a switch's side (bool), a mode's value
    /// (text; `…_mode` beside a switch) and, when the device knows, when it ends (`…_ends`).
    struct CommandValue {
        let device: String
        let skill: String
        let onLabel: String?
        let modeLabel: String?
        let endsLabel: String?

        init(_ device: String, _ skill: String, on: String? = nil, mode: String? = nil, ends: String? = nil) {
            self.device = device
            self.skill = skill
            onLabel = on
            modeLabel = mode
            endsLabel = ends
        }

        var key: String { "\(device).\(skill.split(separator: "_", maxSplits: 1).last ?? "")" }
        var modeKey: String { onLabel == nil ? key : key + "_mode" }
        var endsKey: String { key + "_ends" }
    }

    static let commandValues: [CommandValue] = [
        CommandValue("bottle", "bottle_sterilise", on: "Bottle sterilising"),
        CommandValue("bottle", "bottle_set_uv_intensity", mode: "Bottle UV intensity"),
        CommandValue("bottle", "bottle_auto_clean", on: "Bottle auto-clean"),
        CommandValue("bottle", "bottle_touch_lock", on: "Bottle touch lock"),
        CommandValue("bottle", "bottle_reminders", on: "Bottle drink reminders"),
        CommandValue("bottle", "bottle_daily_reset", on: "Bottle daily reset"),
        CommandValue("bottle", "bottle_set_screen_seconds", mode: "Bottle screen timeout (s)"),
        CommandValue("esp32", "esp32_set_led", on: "ESP32 board LED on"),
        CommandValue("esp32", "esp32_notification_relay", on: "ESP32 notification relay"),
        CommandValue("esp32", "esp32_script_control", on: "ESP32 script running"),
        CommandValue("ring", "ring_set_input_mode", mode: "R12 ring gesture mode"),
        CommandValue("ring", "ring_workout", on: "R12 ring workout running"),
        CommandValue("ring", "ring_measure", on: "R12 ring measuring", mode: "R12 ring measuring what"),
        CommandValue("x5ring", "x5_set_gesture_mode", mode: "X5 ring gesture mode"),
        CommandValue("x5ring", "x5_workout", on: "X5 ring workout running"),
        CommandValue("x5ring", "x5_measure", on: "X5 ring measuring", mode: "X5 ring measuring what",
                     ends: "X5 ring reading ends"),
        CommandValue("band", "band_workout", on: "Smart band workout running"),
        CommandValue("band", "band_night_tracking", on: "Smart band night tracking"),
        CommandValue("band", "band_set_measurement_plan", mode: "Smart band measuring managed by"),
        CommandValue("band", "band_measure", on: "Smart band measuring", mode: "Smart band measuring what"),
        CommandValue("band", "band_find", on: "Smart band buzzing to be found"),
        CommandValue("glasses", "glasses_set_dnd", on: "Glasses Do Not Disturb"),
        CommandValue("glasses", "glasses_set_brightness", mode: "Glasses brightness"),
        CommandValue("glasses", "glasses_set_volume", mode: "Glasses volume"),
        CommandValue("glasses", "glasses_set_screen_timeout", mode: "Glasses screen timeout (s)"),
        CommandValue("glasses", "glasses_open_module", mode: "Glasses open module"),
        CommandValue("glasses", "glasses_notes", on: "Glasses note recording"),
        CommandValue("glasses", "glasses_translate", on: "Glasses translating"),
        CommandValue("glasses", "glasses_captions", on: "Glasses showing captions"),
        CommandValue("glasses", "glasses_jarvis_ai", on: "Jarvis for Glasses AI"),
        CommandValue("glasses", "glasses_navigate", on: "Glasses navigating"),
        CommandValue("dashcam", "dashcam_set_recording", on: "Dashcam recording"),
        CommandValue("lights", "lights_set", on: "Car lights on", mode: "Car lights showing"),
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
            Entry(key: "coding.lead_agent", label: "Agent that needs you / is working", area: "coding", kind: .text),
            Entry(key: "coding.lead_project", label: "Its project", area: "coding", kind: .text),
            Entry(key: "coding.lead_state", label: "Its state", area: "coding", kind: .text),
            Entry(key: "coding.lead_step", label: "What it is doing", area: "coding", kind: .text),
            Entry(key: "coding.lead_waiting", label: "An agent is waiting on you", area: "coding", kind: .bool),
            Entry(key: "coding.claude_5h", label: "Claude plan, 5-hour use", area: "coding", kind: .number, unit: "%"),
            Entry(key: "coding.claude_week", label: "Claude plan, weekly use", area: "coding", kind: .number, unit: "%"),
            Entry(key: "server.connected", label: "Connected to Jarvis", area: "server", kind: .bool),
            Entry(key: "server.status", label: "Server status", area: "server", kind: .text),
            Entry(key: "phone.battery", label: "Phone battery", area: "phone", kind: .number, unit: "%"),
            Entry(key: "phone.charging", label: "Phone charging", area: "phone", kind: .bool),
            Entry(key: "alarm.next", label: "Next alarm or timer", area: "phone", kind: .text),
            Entry(key: "door.state", label: "Door alarm state", area: "home", kind: .text),
            Entry(key: "door.mode", label: "Door alarm mode", area: "home", kind: .text),
            Entry(key: "door.deadline", label: "Door alarm countdown ends", area: "home", kind: .number),
            Entry(key: "car.locked", label: "Car locked", area: "car", kind: .bool),
            Entry(key: "car.running", label: "Car engine running", area: "car", kind: .bool),
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
        for value in commandValues {
            if let label = value.onLabel { all.append(Entry(key: value.key, label: label, area: "wearables", kind: .bool)) }
            if let label = value.modeLabel { all.append(Entry(key: value.modeKey, label: label, area: "wearables", kind: .text)) }
            if let label = value.endsLabel { all.append(Entry(key: value.endsKey, label: label, area: "wearables", kind: .number)) }
        }
        return all
    }()

    static func entries(area: String) -> [Entry] { entries.filter { $0.area == area } }

    static func entry(_ key: String) -> Entry? { entries.first { $0.key == key } }
}
