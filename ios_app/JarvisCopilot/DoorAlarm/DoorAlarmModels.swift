import Foundation

/// The door alarm as `/api/door/state` describes it. Decoded by hand from JSON dictionaries, like the
/// car's models: the hub's data points are only known at runtime (Smart Life's own page for the hub
/// is a mini-app it downloads), so most of this is data, not fixed fields.

/// A data-point value: the hub sends booleans, numbers and strings.
enum DoorValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)
    case none

    init(_ any: Any?) {
        switch any {
        case let n as NSNumber:
            // JSONSerialization gives NSNumber for both; a CFBoolean is a Bool.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let b as Bool: self = .bool(b)
        case let s as String: self = .text(s)
        default: self = .none
        }
    }

    var json: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .text(let s): return s
        case .none: return NSNull()
        }
    }

    var display: String {
        switch self {
        case .bool(let b): return b ? "On" : "Off"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(format: "%.1f", n)
        case .text(let s): return s
        case .none: return "—"
        }
    }
}

struct DoorContact: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// nil when the sensor only reports openings (no closed state).
    let open: Bool?
    let lastOpen: Date?
    let lastClose: Date?
    let instant: Bool
    let activeHome: Bool
    let notifyDisarmed: Bool
    let onOpenPrompt: String

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? "Door"
        open = json["open"] as? Bool
        lastOpen = (json["last_open"] as? Double).map(Date.init(timeIntervalSince1970:))
        lastClose = (json["last_close"] as? Double).map(Date.init(timeIntervalSince1970:))
        instant = json["instant"] as? Bool ?? false
        activeHome = json["active_home"] as? Bool ?? true
        notifyDisarmed = json["notify_disarmed"] as? Bool ?? false
        onOpenPrompt = json["on_open_prompt"] as? String ?? ""
    }
}

/// One of the hub's data points (a setting or a reading).
struct DoorDataPoint: Identifiable, Equatable, Sendable {
    let id: Int
    let code: String
    let name: String
    /// bool | enum | value | string | raw | bitmap
    let type: String
    let writable: Bool
    let range: [String]
    let min: Int?
    let max: Int?
    let step: Int
    let unit: String
    var value: DoorValue

    init(json: [String: Any], value: DoorValue) {
        id = json["id"] as? Int ?? 0
        code = json["code"] as? String ?? ""
        let raw = json["name"] as? String ?? ""
        name = raw.isEmpty ? code : raw
        type = json["type"] as? String ?? "raw"
        writable = json["writable"] as? Bool ?? false
        range = json["range"] as? [String] ?? []
        min = json["min"] as? Int
        max = json["max"] as? Int
        step = Swift.max(1, json["step"] as? Int ?? 1)
        unit = json["unit"] as? String ?? ""
        self.value = value
    }
}

struct DoorAlarmInfo: Equatable, Sendable {
    /// disarmed | arming | armed_away | armed_home | entry | triggered
    let state: String
    let mode: String?
    let secondsLeft: Int?
    let contactName: String?
    let sirenOn: Bool
    let since: Date?
    let exitDelay: Int
    let entryDelay: Int
    let sirenDuration: Int

    init(json: [String: Any]) {
        state = json["state"] as? String ?? "disarmed"
        mode = json["mode"] as? String
        secondsLeft = json["seconds_left"] as? Int
        contactName = json["contact_name"] as? String
        sirenOn = json["siren_on"] as? Bool ?? false
        since = (json["since"] as? Double).map(Date.init(timeIntervalSince1970:))
        let s = json["settings"] as? [String: Any] ?? [:]
        exitDelay = s["exit_delay"] as? Int ?? 60
        entryDelay = s["entry_delay"] as? Int ?? 30
        sirenDuration = s["siren_duration"] as? Int ?? 180
    }

    var isArmed: Bool { ["arming", "armed_away", "armed_home", "entry", "triggered"].contains(state) }
    var isAlerting: Bool { state == "entry" || state == "triggered" }

    var title: String {
        switch state {
        case "arming": return "Arming"
        case "armed_away": return "Armed away"
        case "armed_home": return "Armed home"
        case "entry": return "Door opened"
        case "triggered": return "Alarm"
        default: return "Disarmed"
        }
    }
}

struct DoorLinks: Equatable, Sendable {
    let localAlive: Bool
    let cloudAlive: Bool
    let localState: String
    let localIP: String?
    let localVersion: String?
    let rttMs: Int?
    let rssi: Int?
    let localError: String?
    let cloudState: String
    let cloudError: String?

    init(json: [String: Any]) {
        let local = json["local"] as? [String: Any] ?? [:]
        let cloud = json["cloud"] as? [String: Any] ?? [:]
        localAlive = json["local_alive"] as? Bool ?? false
        cloudAlive = json["cloud_alive"] as? Bool ?? false
        localState = local["state"] as? String ?? "unconfigured"
        localIP = local["ip"] as? String
        localVersion = local["version"] as? String
        rttMs = local["rtt_ms"] as? Int
        rssi = local["rssi"] as? Int
        localError = (local["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        cloudState = cloud["state"] as? String ?? "off"
        cloudError = (cloud["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct DoorSetup: Equatable, Sendable {
    let credentials: Bool
    let region: String
    let hub: Bool
    let hubName: String?
    let proxy: String?
    let cloud: String

    init(json: [String: Any]) {
        credentials = json["credentials"] as? Bool ?? false
        region = json["region"] as? String ?? "us"
        hub = json["hub"] as? Bool ?? false
        hubName = json["hub_name"] as? String
        proxy = json["proxy"] as? String
        cloud = json["cloud"] as? String ?? "off"
    }
}

struct DoorApproval: Identifiable, Equatable, Sendable {
    let id: String
    /// disarm | silence
    let command: String
    let title: String
    let source: String
    let ageSeconds: Int
    let expiresInSeconds: Int
    let deadline: Date

    init?(json: [String: Any], now: Date = Date()) {
        guard let id = json["id"] as? String, let command = json["command"] as? String else { return nil }
        self.id = id
        self.command = command
        title = json["title"] as? String ?? command
        source = json["source"] as? String ?? "Jarvis"
        ageSeconds = json["age_s"] as? Int ?? 0
        expiresInSeconds = json["expires_in_s"] as? Int ?? 120
        deadline = now.addingTimeInterval(TimeInterval(expiresInSeconds))
    }
}

struct DoorState: Equatable, Sendable {
    let setup: DoorSetup
    let alarm: DoorAlarmInfo
    let hubName: String
    let productName: String?
    let contacts: [DoorContact]
    let dataPoints: [DoorDataPoint]
    let roles: [String: [String]]
    let links: DoorLinks
    let approvals: [DoorApproval]

    init(json: [String: Any]) {
        setup = DoorSetup(json: json["setup"] as? [String: Any] ?? [:])
        alarm = DoorAlarmInfo(json: json["alarm"] as? [String: Any] ?? [:])
        let hub = json["hub"] as? [String: Any] ?? [:]
        hubName = hub["name"] as? String ?? "Door Alarm"
        productName = hub["product_name"] as? String
        contacts = (hub["contacts"] as? [[String: Any]] ?? []).map(DoorContact.init(json:))
        let values = hub["values"] as? [String: Any] ?? [:]
        dataPoints = (hub["dps"] as? [[String: Any]] ?? []).map { dp in
            let code = dp["code"] as? String ?? ""
            return DoorDataPoint(json: dp, value: DoorValue((values[code] as? [String: Any])?["value"]))
        }
        roles = hub["roles"] as? [String: [String]] ?? [:]
        links = DoorLinks(json: hub["link"] as? [String: Any] ?? [:])
        approvals = (json["approvals"] as? [[String: Any]] ?? []).compactMap { DoorApproval(json: $0) }
    }

    /// The settings the hub lets you change, door sensors left out.
    var settings: [DoorDataPoint] {
        let doors = Set(roles["door"] ?? [])
        return dataPoints.filter { $0.writable && !doors.contains($0.code) }
    }

    /// Read-only readings (battery, tamper, signal…), door sensors left out.
    var readings: [DoorDataPoint] {
        let doors = Set(roles["door"] ?? [])
        return dataPoints.filter { !$0.writable && !doors.contains($0.code) }
    }

    var openContacts: [DoorContact] { contacts.filter { $0.open == true } }
}

/// One line of history.
struct DoorEvent: Identifiable, Equatable, Sendable {
    let id: String
    let time: Date
    let kind: String
    let text: String
    let contact: String?
    let open: Bool?
    let source: String?

    init(json: [String: Any], index: Int) {
        let t = json["t"] as? Double ?? 0
        time = Date(timeIntervalSince1970: t)
        kind = json["kind"] as? String ?? ""
        contact = json["contact"] as? String
        open = json["open"] as? Bool
        source = json["source"] as? String
        id = "\(t)-\(index)"
        switch kind {
        case "door":
            let name = json["name"] as? String ?? "A door"
            let missed = json["missed"] as? Bool ?? false
            text = "\(name) \(open == false ? "closed" : "opened")\(missed ? " (while offline)" : "")"
        case "dp":
            text = "\(json["code"] as? String ?? "Setting") → \(DoorValue(json["value"]).display)"
        default:
            text = json["text"] as? String ?? (json["state"] as? String ?? kind)
        }
    }
}
