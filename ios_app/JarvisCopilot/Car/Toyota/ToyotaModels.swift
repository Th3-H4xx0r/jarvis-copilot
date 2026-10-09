import CoreLocation
import Foundation

/// The Toyota account as the Jarvis server sees it (`/api/car/state`). The server reads it from
/// Pranav's Home Assistant, which runs the Toyota integration.
struct ToyotaAccount: Equatable {
    enum State: String {
        case notInstalled = "not_installed", signedOut = "signed_out", signedIn = "signed_in"
        case reauth, unavailable, haUnreachable = "ha_unreachable"
    }

    var state: State
    var email: String?
    var reason: String?

    init(state: State, email: String? = nil, reason: String? = nil) {
        self.state = state
        self.email = email
        self.reason = reason
    }

    init(json: [String: Any]) {
        state = State(rawValue: json["state"] as? String ?? "") ?? .unavailable
        email = json["email"] as? String
        reason = json["reason"] as? String
    }

    var isSignedIn: Bool { state == .signedIn }
    /// The sign-in sheet is what fixes it.
    var needsSignIn: Bool { state == .signedOut || state == .reauth }

    /// Why the Toyota parts are greyed out; nil when they can be used.
    var blockedReason: String? {
        switch state {
        case .signedIn: return nil
        case .signedOut: return "Sign in with Toyota to use these."
        case .reauth: return "Toyota signed Jarvis out. Sign in again."
        case .notInstalled: return "Toyota isn't set up in Home Assistant yet."
        case .haUnreachable: return reason ?? "Home Assistant isn't reachable."
        case .unavailable: return reason ?? "Toyota isn't answering right now."
        }
    }
}

/// The remote commands, named as the server takes them.
enum ToyotaCommand: String, CaseIterable, Identifiable {
    case start, stop, lock, unlock
    case trunkLock = "trunk_lock", trunkUnlock = "trunk_unlock"
    case lights, horn, buzzer
    case hazardsOn = "hazards_on", hazardsOff = "hazards_off"

    var id: String { rawValue }

    /// Start/Stop and Hazards on/off share one button, so a result stays on it when it flips.
    var slot: String {
        switch self {
        case .start, .stop: return "start"
        case .hazardsOn, .hazardsOff: return "hazards"
        default: return rawValue
        }
    }

    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .lock: return "Lock"
        case .unlock: return "Unlock"
        case .trunkLock: return "Lock Trunk"
        case .trunkUnlock: return "Unlock Trunk"
        case .lights: return "Lights"
        case .horn: return "Horn"
        case .buzzer: return "Buzzer"
        case .hazardsOn: return "Hazards"
        case .hazardsOff: return "Hazards Off"
        }
    }

    var symbol: String {
        switch self {
        case .start, .stop: return "power"
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .trunkLock: return "car.rear.fill"
        case .trunkUnlock: return "car.side.rear.open.fill"
        case .lights: return "headlight.high.beam.fill"
        case .horn: return "horn.fill"
        case .buzzer: return "bell.fill"
        case .hazardsOn, .hazardsOff: return "exclamationmark.triangle"
        }
    }
}

/// The car, from Toyota's cloud. Any part the car doesn't report is nil and its row is hidden.
struct ToyotaCar: Equatable {
    struct Climate: Equatable {
        var custom: Bool?
        var temp: Double?
        var unit: String
        var min: Double
        var max: Double
        var step: Double
        var defrostFront: Bool?
        var defrostRear: Bool?
    }

    struct Tires: Equatable {
        var fl: Double?, fr: Double?, rl: Double?, rr: Double?
        var unit: String
        var updatedAt: Date?
        var warnings: [String]
    }

    /// Doors, windows, trunk, hood: which parts are open, and whether it's locked (when known).
    struct Opening: Equatable {
        var open: [String]
        var locked: Bool?
    }

    struct HealthItem: Equatable, Identifiable {
        var id: String
        var title: String
        var ok: Bool
        var detail: String
    }

    struct Location: Equatable {
        var lat: Double
        var lon: Double
        var at: Date?
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
        static func == (a: Location, b: Location) -> Bool { a.lat == b.lat && a.lon == b.lon && a.at == b.at }
    }

    var rangeMi: Double?
    var fuelPct: Double?
    var odometerMi: Double?
    var updatedAt: Date?
    var running: Bool
    var commands: Set<ToyotaCommand>
    var climate: Climate?
    var tires: Tires?
    var doors: Opening?
    var windows: Opening?
    var trunk: Opening?
    var hood: Opening?
    var moonroof: Opening?
    var health: [HealthItem]
    var location: Location?

    init(json o: [String: Any]) {
        rangeMi = Self.number(o["range_mi"])
        fuelPct = Self.number(o["fuel_pct"])
        odometerMi = Self.number(o["odometer_mi"])
        updatedAt = Self.date(o["updated_at"])
        running = o["running"] as? Bool ?? false
        commands = Set((o["commands"] as? [String] ?? []).compactMap(ToyotaCommand.init(rawValue:)))
        if let c = o["climate"] as? [String: Any] {
            climate = Climate(custom: c["custom"] as? Bool, temp: Self.number(c["temp"]),
                              unit: c["unit"] as? String ?? "°F",
                              min: Self.number(c["min"]) ?? 60, max: Self.number(c["max"]) ?? 85,
                              step: Self.number(c["step"]) ?? 1,
                              defrostFront: c["defrost_front"] as? Bool, defrostRear: c["defrost_rear"] as? Bool)
        }
        if let t = o["tires"] as? [String: Any] {
            tires = Tires(fl: Self.number(t["fl"]), fr: Self.number(t["fr"]), rl: Self.number(t["rl"]),
                          rr: Self.number(t["rr"]), unit: t["unit"] as? String ?? "psi",
                          updatedAt: Self.date(t["updated_at"]), warnings: t["warnings"] as? [String] ?? [])
        }
        doors = Self.opening(o["doors"])
        windows = Self.opening(o["windows"])
        trunk = Self.opening(o["trunk"])
        hood = Self.opening(o["hood"])
        moonroof = Self.opening(o["moonroof"])
        health = (o["health"] as? [[String: Any]] ?? []).compactMap { h in
            guard let id = h["id"] as? String, let title = h["title"] as? String else { return nil }
            return HealthItem(id: id, title: title, ok: h["ok"] as? Bool ?? true, detail: h["detail"] as? String ?? "")
        }
        if let l = o["location"] as? [String: Any], let lat = Self.number(l["lat"]), let lon = Self.number(l["lon"]) {
            location = Location(lat: lat, lon: lon, at: Self.date(l["at"]))
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let n = (raw as? NSNumber)?.doubleValue, n.isFinite, abs(n) < 1e9 else { return nil }
        return n
    }

    private static func opening(_ raw: Any?) -> Opening? {
        guard let o = raw as? [String: Any] else { return nil }
        return Opening(open: o["open"] as? [String] ?? [], locked: o["locked"] as? Bool)
    }

    static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
