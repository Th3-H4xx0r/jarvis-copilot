import CoreGraphics
import Foundation

/// What Holo Drop does when an item lands.
enum HoloAction: String, CaseIterable, Identifiable {
    case save, open, copy, saveOpen = "save_open", saveCopy = "save_copy"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .save: return "Save"
        case .open: return "Open"
        case .copy: return "Copy"
        case .saveOpen: return "Save + Open"
        case .saveCopy: return "Save + Copy"
        }
    }
    var saves: Bool { self == .save || self == .saveOpen || self == .saveCopy }
    var opens: Bool { self == .open || self == .saveOpen }
    var copies: Bool { self == .copy || self == .saveCopy }
}

/// A device you can drop onto (`GET /api/holo-drop/devices`).
struct HoloDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String           // iphone | ipad | mac | web | glasses | pod
    let online: Bool
    let accepts: [String]
    let aim: Bool
    let defaultAction: HoloAction
    let lanURL: URL?
    let lanToken: String?
    var bearingDeg: Double?
    var bearingConfidence: Double
    var distance: Double?
    /// Strongest Bluetooth signal right now (the app's popup ranks devices; highlighted).
    var nearest = false

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, let kind = o["kind"] as? String else { return nil }
        self.id = id
        self.kind = kind
        name = o["name"] as? String ?? kind.capitalized
        online = o["online"] as? Bool ?? false
        accepts = o["accepts"] as? [String] ?? ["link", "text"]
        aim = o["aim"] as? Bool ?? false
        defaultAction = HoloAction(rawValue: o["default_action"] as? String ?? "") ?? .open
        let lan = o["lan"] as? [String: Any]
        lanURL = (lan?["url"] as? String).flatMap(URL.init(string:))
        lanToken = lan?["token"] as? String
        let b = o["bearing"] as? [String: Any]
        bearingDeg = (b?["deg"] as? NSNumber)?.doubleValue
        bearingConfidence = (b?["confidence"] as? NSNumber)?.doubleValue ?? 0
        distance = (o["distance_m"] as? NSNumber)?.doubleValue
    }

    var symbol: String {
        switch kind {
        case "mac": return "laptopcomputer"
        case "ipad": return "ipad"
        case "iphone": return "iphone"
        case "web": return "globe"
        case "glasses": return "eyeglasses"
        case "pod": return "circle.circle"
        default: return "questionmark.circle"
        }
    }

    func accepts(_ item: HoloItem) -> Bool { accepts.contains(item.kind) }
}

/// The thing being dropped.
enum HoloItem: Equatable {
    case link(URL, title: String?)
    case text(String)
    case file(URL, name: String, mime: String, kind: String)   // kind: image | video | file

    var kind: String {
        switch self {
        case .link: return "link"
        case .text: return "text"
        case .file(_, _, _, let kind): return kind
        }
    }

    var caption: String {
        switch self {
        case .link(let url, let title): return title ?? url.host ?? url.absoluteString
        case .text(let t): return String(t.prefix(80))
        case .file(_, let name, _, _): return name
        }
    }

    var symbol: String {
        switch kind {
        case "link": return "link"
        case "text": return "text.alignleft"
        case "image": return "photo"
        case "video": return "film"
        default: return "doc"
        }
    }
}

/// Where the item lands on a Mac's screen (fractions of its visible frame).
struct HoloPosition: Equatable {
    var x: Double
    var y: Double
    static let center = HoloPosition(x: 0.5, y: 0.5)
    func clamped() -> HoloPosition { HoloPosition(x: min(1, max(0, x)), y: min(1, max(0, y))) }
}

/// A screen layout for the aiming map (`GET /devices/<id>/screen`).
struct HoloScreen: Equatable {
    struct Window: Equatable { let rect: CGRect; let app: String }
    let size: CGSize
    let windows: [Window]

    init(size: CGSize, windows: [Window]) { self.size = size; self.windows = windows }

    init?(json o: [String: Any]) {
        guard let w = (o["width"] as? NSNumber)?.doubleValue, let h = (o["height"] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        size = CGSize(width: w, height: h)
        windows = (o["windows"] as? [[String: Any]] ?? []).compactMap { win in
            guard let x = (win["x"] as? NSNumber)?.doubleValue, let y = (win["y"] as? NSNumber)?.doubleValue,
                  let ww = (win["w"] as? NSNumber)?.doubleValue, let hh = (win["h"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(rect: CGRect(x: x, y: y, width: ww, height: hh), app: win["app"] as? String ?? "")
        }
    }
}

/// Bubble placement and fling resolution for the Orbit popup.
enum HoloOrbitLayout {
    /// Devices with a bearing sit on a circle at (bearing − heading); the rest share a ring
    /// at the bottom. Angles: 0° = straight up the screen, clockwise.
    static func positions(devices: [HoloDevice], heading: Double?, size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.48)
        let radius = min(size.width, size.height) * 0.36
        var out: [String: CGPoint] = [:]
        var placedAngles: [Double] = []
        let located = devices.filter { $0.bearingDeg != nil && heading != nil }
        let others = devices.filter { $0.bearingDeg == nil || heading == nil }
        for d in located {
            var angle = normalized((d.bearingDeg ?? 0) - (heading ?? 0))
            while placedAngles.contains(where: { abs(angleDelta($0, angle)) < 28 }) { angle = normalized(angle + 30) }
            placedAngles.append(angle)
            out[d.id] = point(center: center, radius: radius, degrees: angle)
        }
        if !others.isEmpty {
            // Evenly around the circle when nothing has a real bearing; else a bottom arc.
            let span: (Double, Double) = located.isEmpty ? (0, 360) : (120, 240)
            let step = (span.1 - span.0) / Double(located.isEmpty ? others.count : max(1, others.count - 1))
            for (i, d) in others.enumerated() {
                let angle = located.isEmpty ? span.0 + step * Double(i)
                                            : (others.count == 1 ? 180 : span.0 + step * Double(i))
                out[d.id] = point(center: center, radius: radius, degrees: angle)
            }
        }
        return out
    }

    /// The device a fling points at: the bubble within 35° of the fling's direction, nearest in angle.
    static func target(forVelocity v: CGVector, from origin: CGPoint, positions: [String: CGPoint]) -> String? {
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        guard speed > 300 else { return nil }                      // a drag, not a fling
        let flingAngle = degrees(dx: v.dx, dy: v.dy)
        var best: (String, Double)?
        for (id, p) in positions {
            let delta = abs(angleDelta(degrees(dx: p.x - origin.x, dy: p.y - origin.y), flingAngle))
            if delta <= 35, best == nil || delta < best!.1 { best = (id, delta) }
        }
        return best?.0
    }

    static func point(center: CGPoint, radius: Double, degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: center.x + radius * sin(r), y: center.y - radius * cos(r))
    }

    static func degrees(dx: Double, dy: Double) -> Double { normalized(atan2(dx, -dy) * 180 / .pi) }
    static func normalized(_ a: Double) -> Double { let m = a.truncatingRemainder(dividingBy: 360); return m < 0 ? m + 360 : m }
    static func angleDelta(_ a: Double, _ b: Double) -> Double { let d = normalized(a - b); return d > 180 ? d - 360 : d }
}

/// What the popup shows when the drop is done.
enum HoloSendResult: Equatable {
    case landed(String)          // "Landed on MacBook · Opened"
    case sent(String)            // "Sent — waiting for MacBook"
    case failed(String)
}

/// A live direction reading from the app's sensors (UWB, camera look, chirp, learned).
struct HoloLiveReading: Equatable {
    var deg: Double?
    var confidence: Double
    var distance: Double?
    var source: String
}

extension HoloDevice {
    /// This device with a live reading laid over what the server remembered: a reading wins
    /// when it has a bearing at least as confident, or brings a distance the server lacked.
    func applying(_ r: HoloLiveReading?, nearest: Bool) -> HoloDevice {
        var d = self
        d.nearest = nearest
        guard let r else { return d }
        if let deg = r.deg, r.confidence >= (bearingDeg == nil ? 0 : bearingConfidence) {
            d.bearingDeg = deg
            d.bearingConfidence = r.confidence
        }
        if let m = r.distance { d.distance = m }
        return d
    }
}

/// "Opened", "Saved + copied": a landing's outcome in words (popup, cards, banners).
enum HoloOutcomeWords {
    static func text(_ outcome: String) -> String {
        switch outcome {
        case "opened": return "Opened"
        case "saved": return "Saved"
        case "copied": return "Copied"
        case "saved_opened": return "Saved + opened"
        case "saved_copied": return "Saved + copied"
        case "shown": return "Shown"
        default: return ""
        }
    }
}

/// Each device's arrival default, kept on the server as one JSON object (`defaults` setting):
/// `{"<device id>": "save" | "open" | "copy" | "save_open" | "save_copy"}`.
enum HoloDefaults {
    static func parse(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }

    static func action(json: String, device: String, fallback: HoloAction) -> HoloAction {
        parse(json)[device].flatMap(HoloAction.init(rawValue:)) ?? fallback
    }

    static func merge(json: String, device: String, action: HoloAction) -> String {
        var o = parse(json)
        o[device] = action.rawValue
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
