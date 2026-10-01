import Foundation

/// What a file on the dashcam's card is. Parking clips are recorded while the car is off;
/// events are G-sensor or "save this moment" clips, which the camera keeps (locks).
enum DashcamClipKind: String, Codable, CaseIterable, Sendable {
    case normal, event, parking, photo

    var label: String {
        switch self {
        case .normal: return "Drive"
        case .event: return "Event"
        case .parking: return "Parking"
        case .photo: return "Photo"
        }
    }
}

enum DashcamLens: String, Codable, CaseIterable, Sendable {
    case front, rear, inside
}

/// The SoC family a camera speaks. Only Viidure and Novatek are driven; the rest are
/// recognised so the setup screen can say which one was found (protocol.md §1).
enum DashcamFamily: String, Codable, Sendable {
    case viidure, novatek, hisilicon, allwinner, mstar, huiying, unknown

    var supported: Bool { self == .viidure || self == .novatek }
}

/// One file on the camera's SD card.
struct DashcamFile: Codable, Hashable, Identifiable, Sendable {
    let path: String
    let kind: DashcamClipKind
    let lens: DashcamLens
    let start: Date
    let durationS: Double
    let size: Int64
    var locked: Bool = false
    var folder: String = ""
    var gpsPath: String? = nil

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var end: Date { start.addingTimeInterval(durationS) }
    var isVideo: Bool { kind != .photo }
}

/// One GPS fix: Unix seconds, degrees, metres per second, degrees from north.
struct DashcamFix: Codable, Equatable, Sendable {
    var t: Double
    var lat: Double
    var lon: Double
    var speed: Double?
    var heading: Double?

    /// The server's wire form: `[t, lat, lon, speed, heading]` with nulls.
    var row: [Any] {
        [t, lat, lon, speed.map { $0 as Any } ?? NSNull(), heading.map { $0 as Any } ?? NSNull()]
    }

    init(t: Double, lat: Double, lon: Double, speed: Double?, heading: Double?) {
        self.t = t; self.lat = lat; self.lon = lon; self.speed = speed; self.heading = heading
    }

    /// Decodes the server's row form; nil for anything malformed.
    init?(row: Any) {
        guard let a = row as? [Any], a.count >= 3,
              let t = (a[0] as? NSNumber)?.doubleValue,
              let lat = (a[1] as? NSNumber)?.doubleValue,
              let lon = (a[2] as? NSNumber)?.doubleValue else { return nil }
        self.init(t: t, lat: lat, lon: lon,
                  speed: a.count > 3 ? (a[3] as? NSNumber)?.doubleValue : nil,
                  heading: a.count > 4 ? (a[4] as? NSNumber)?.doubleValue : nil)
    }
}

struct DashcamCameraInfo: Codable, Equatable, Sendable {
    var id: String
    var family: DashcamFamily
    var model: String = ""
    var brand: String = ""
    var soc: String = ""
    var firmware: String = ""
    var lenses: Int = 1
    /// The camera restarts recording by itself when a phone connects (`getmediainfo.autorecord`).
    var autorecord: Bool = false

    var wire: [String: Any] {
        ["id": id, "family": family.rawValue, "model": model, "brand": brand, "soc": soc,
         "firmware": firmware, "lenses": lenses]
    }
}

struct DashcamSDInfo: Codable, Equatable, Sendable {
    var ok: Bool
    var totalBytes: Int64?
    var freeBytes: Int64?
}

/// One camera setting with its choices, built from the camera's own capability list.
struct DashcamSettingItem: Codable, Equatable, Identifiable, Sendable {
    struct Option: Codable, Equatable, Hashable, Sendable {
        let code: String
        let label: String
    }
    let name: String
    var value: String?
    var options: [Option] = []
    var range: String? = nil

    var id: String { name }
    var currentLabel: String? {
        guard let value else { return nil }
        return options.first { $0.code == value }?.label ?? value
    }
}

enum DashcamError: LocalizedError, Equatable {
    case notConnected
    case camera(String)
    case unsupported(String)
    case badReply(String)
    case http(Int)
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "not connected to the dashcam's Wi‑Fi"
        case .camera(let m): return "the dashcam said: \(m)"
        case .unsupported(let m): return m
        case .badReply(let m): return "unexpected reply from the dashcam (\(m))"
        case .http(let s): return "the dashcam answered HTTP \(s)"
        case .busy(let m): return m
        }
    }
}

extension Date {
    /// ISO-8601 in UTC with whole seconds, the server's clip-time format.
    var dashcamISO: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: self)
    }

    static func dashcamISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
