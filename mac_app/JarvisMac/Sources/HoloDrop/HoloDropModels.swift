import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// Holo Drop's data and wire format (docs/superpowers/plans/2026-11-14-holo-drop.md, "API
// contract"). Compiled into the app AND the Share extension (project.yml), so nothing here
// may use an app-only type (AppModel, J, Prefs…). Everything is pure and tested
// (Tests/HoloDropTests.swift).

/// Loose JSON reads — the app's `J`, which the Share extension doesn't have.
enum HJ {
    static func s(_ v: Any?, _ fallback: String = "") -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return fallback
    }

    static func d(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func b(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false) }
    static func obj(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
    static func arr(_ v: Any?) -> [[String: Any]] { (v as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
}

/// What a drop carries.
enum HoloKind: String, CaseIterable, Sendable {
    case link, text, image, video, file

    /// Travels inside the JSON (no bytes to fetch).
    var inline: Bool { self == .link || self == .text }

    /// A file's kind by its type: photos and videos are told apart (Photos on the phone).
    static func forFile(_ url: URL) -> HoloKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }

    static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// What the receiver does on arrival. Each device has a default; the popup can change it for
/// one drop.
enum HoloAction: String, CaseIterable, Identifiable, Sendable {
    case save, open, copy
    case saveOpen = "save_open"
    case saveCopy = "save_copy"

    var id: String { rawValue }

    var title: String {
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

    /// Unknown or missing: open (the server's default for a Mac).
    static func parse(_ raw: Any?) -> HoloAction? { HoloAction(rawValue: HJ.s(raw)) }
}

/// How a drop ended on the receiver (`POST /drops/<id>/landed`).
enum HoloOutcome: String, Sendable {
    case opened, saved, copied, shown, failed
    case savedOpened = "saved_opened"
    case savedCopied = "saved_copied"

    /// What happened, from the steps that worked. Nothing worked: failed.
    init(saved: Bool, opened: Bool, copied: Bool, shown: Bool) {
        switch (saved, opened, copied) {
        case (true, true, _): self = .savedOpened
        case (true, false, true): self = .savedCopied
        case (true, false, false): self = .saved
        case (false, true, _): self = .opened
        case (false, false, true): self = .copied
        default: self = shown ? .shown : .failed
        }
    }

    /// "Landed on iPhone · Saved".
    var label: String {
        switch self {
        case .opened: return "Opened"
        case .saved: return "Saved"
        case .copied: return "Copied"
        case .shown: return "Shown"
        case .failed: return "Didn't land"
        case .savedOpened: return "Saved and opened"
        case .savedCopied: return "Saved and copied"
        }
    }
}

/// Where a drop lands: fractions (0–1) of the target screen, from its top-left corner.
struct HoloPosition: Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }

    init?(json: Any?) {
        let o = HJ.obj(json)
        guard let x = HJ.d(o["x"]), let y = HJ.d(o["y"]), x.isFinite, y.isFinite else { return nil }
        self.init(x: x, y: y)
    }

    var json: [String: Any] { ["x": x, "y": y] }
}

/// A receiver's direct endpoint on the local network.
struct HoloLan: Equatable, Sendable {
    let url: String
    let token: String
    /// Unix seconds; 0 = no expiry given.
    let expires: Double

    init?(json: Any?) {
        let o = HJ.obj(json)
        let url = HJ.s(o["url"]), token = HJ.s(o["token"])
        guard !url.isEmpty, !token.isEmpty else { return nil }
        self.url = url
        self.token = token
        expires = HJ.d(o["expires"]) ?? 0
    }

    init(url: String, token: String, expires: Double) {
        self.url = url
        self.token = token
        self.expires = expires
    }

    func usable(at now: Date = Date()) -> Bool { expires <= 0 || expires > now.timeIntervalSince1970 }
}

/// One of his devices that can receive (`GET /devices`).
struct HoloDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// iphone, ipad, mac, web, glasses, pod.
    let kind: String
    let online: Bool
    let accepts: [String]
    /// A Mac: drops can be aimed at a spot on its screen.
    let aim: Bool
    let defaultAction: HoloAction
    let lan: HoloLan?
    /// Degrees from "straight ahead", clockwise, as the caller last saw it.
    let bearing: Double?
    let bearingConfidence: Double
    let distance: Double?

    init?(json o: [String: Any]) {
        let id = HJ.s(o["id"])
        guard !id.isEmpty else { return nil }
        self.id = id
        kind = HJ.s(o["kind"], "mac")
        name = HJ.s(o["name"]).isEmpty ? kind.capitalized : HJ.s(o["name"])
        online = HJ.b(o["online"])
        accepts = (o["accepts"] as? [Any] ?? []).map { HJ.s($0) }
        aim = HJ.b(o["aim"])
        defaultAction = HoloAction.parse(o["default_action"]) ?? .open
        lan = HoloLan(json: o["lan"])
        let b = HJ.obj(o["bearing"])
        bearing = HJ.d(b["deg"])
        bearingConfidence = HJ.d(b["confidence"]) ?? 0
        distance = HJ.d(o["distance_m"])
    }

    init(id: String, name: String, kind: String, online: Bool = true, accepts: [String] = [],
         aim: Bool = false, defaultAction: HoloAction = .open, lan: HoloLan? = nil,
         bearing: Double? = nil, bearingConfidence: Double = 0, distance: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.online = online
        self.accepts = accepts
        self.aim = aim
        self.defaultAction = defaultAction
        self.lan = lan
        self.bearing = bearing
        self.bearingConfidence = bearingConfidence
        self.distance = distance
    }

    static func list(_ reply: [String: Any]) -> [HoloDevice] {
        HJ.arr(reply["devices"]).compactMap(HoloDevice.init(json:))
    }

    /// No list means everything (an older server).
    func accepts(_ k: HoloKind) -> Bool { accepts.isEmpty || accepts.contains(k.rawValue) }

    var symbol: String {
        switch kind {
        case "iphone": return "iphone"
        case "ipad": return "ipad"
        case "mac": return "laptopcomputer"
        case "web": return "globe"
        case "glasses": return "eyeglasses"
        case "pod": return "circle.circle"
        default: return "display"
        }
    }
}

/// A drop as the server keeps it (`GET /drops/<id>`, the bridge's `drop` frame, `/pending`).
struct HoloDropRecord: Identifiable, Equatable, Sendable {
    let id: String
    let kind: HoloKind
    let from: String
    let fromName: String
    let target: String
    let name: String
    let mime: String
    let size: Int
    let text: String
    let url: String
    let title: String
    let action: HoloAction?
    let position: HoloPosition?
    let state: String
    let outcome: String
    let created: Date?

    init?(json o: [String: Any]) {
        guard let kind = HoloKind(rawValue: HJ.s(o["kind"])) else { return nil }
        id = HJ.s(o["id"])
        self.kind = kind
        from = HJ.s(o["from"], HJ.s(o["sender"]))
        fromName = HJ.s(o["from_name"])
        target = HJ.s(o["target"])
        name = HJ.s(o["name"])
        mime = HJ.s(o["mime"])
        size = Int(HJ.d(o["size"]) ?? 0)
        text = HJ.s(o["text"])
        url = HJ.s(o["url"])
        title = HJ.s(o["title"])
        action = HoloAction.parse(o["action"])
        position = HoloPosition(json: o["position"])
        state = HJ.s(o["state"])
        outcome = HJ.s(o["outcome"])
        if let t = HJ.d(o["created"]), t > 0 {
            created = Date(timeIntervalSince1970: t)
        } else if let s = o["created"] as? String {
            created = ISO8601DateFormatter().date(from: s)
        } else {
            created = nil
        }
    }

    /// The link to open: a link drop's URL, or a text drop that is nothing but one.
    var webURL: URL? {
        let raw = (kind == .link ? (url.isEmpty ? text : url) : kind == .text ? text : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: \.isWhitespace), let u = URL(string: raw),
              let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else { return nil }
        return u
    }

    /// The card's caption.
    var displayName: String {
        switch kind {
        case .link:
            if !title.isEmpty { return title }
            return webURL?.host ?? (url.isEmpty ? "Link" : url)
        case .text:
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.isEmpty ? "Text" : String(line.prefix(80))
        default:
            return name.isEmpty ? "File" : name
        }
    }

    /// The landed frame's sentence: "Landed on iPhone · Saved".
    static func landedLine(device: String, outcome raw: String, error: String? = nil) -> String {
        guard let outcome = HoloOutcome(rawValue: raw) else { return "Landed on \(device)" }
        if outcome == .failed {
            return "Didn't land on \(device)" + ((error ?? "").isEmpty ? "" : " — \(error!)")
        }
        return "Landed on \(device) · \(outcome.label)"
    }
}

/// What the Mac is sending.
enum HoloItem: Equatable, Sendable {
    case link(URL, title: String?)
    case text(String)
    case files([URL])

    /// Pasted or dropped text that's just a web address goes as a link.
    static func fromText(_ raw: String) -> HoloItem? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains(where: \.isWhitespace), let u = URL(string: t),
           let s = u.scheme?.lowercased(), ["http", "https"].contains(s), u.host != nil {
            return .link(u, title: nil)
        }
        return .text(t)
    }

    var kinds: [HoloKind] {
        switch self {
        case .link: return [.link]
        case .text: return [.text]
        case .files(let urls): return urls.map(HoloKind.forFile)
        }
    }

    var caption: String {
        switch self {
        case .link(let u, let title): return (title?.isEmpty == false ? title! : nil) ?? u.host ?? u.absoluteString
        case .text(let t):
            let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
            return String(line.prefix(60))
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        }
    }

    var detail: String {
        switch self {
        case .link(let u, _): return u.host ?? ""
        case .text(let t): return "\(t.count) characters"
        case .files(let urls):
            let bytes = urls.reduce(Int64(0)) { sum, u in
                sum + Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    var symbol: String {
        switch self {
        case .link: return "link"
        case .text: return "text.alignleft"
        case .files(let urls):
            switch urls.first.map(HoloKind.forFile) {
            case .image: return "photo"
            case .video: return "film"
            default: return "doc"
            }
        }
    }
}

/// Request bodies and paths, exactly as the contract spells them.
enum HoloWire {
    static let base = "/api/holo-drop"

    /// `POST /drops` (JSON form) for a link or text; with `direct`, a drop of any kind that
    /// already went over the LAN (with the receiver's `outcome`), so history still records it.
    static func inlineDrop(kind: HoloKind, target: String, text: String? = nil, url: String? = nil,
                           action: HoloAction?, position: HoloPosition? = nil, title: String? = nil,
                           direct: Bool = false, name: String? = nil, mime: String? = nil,
                           outcome: HoloOutcome? = nil) -> [String: Any] {
        var body: [String: Any] = ["kind": kind.rawValue, "target": target]
        if let text { body["text"] = text }
        if let url { body["url"] = url }
        if let action { body["action"] = action.rawValue }
        if let position { body["position"] = position.json }
        if let title, !title.isEmpty { body["title"] = title }
        if let name, !name.isEmpty { body["name"] = name }
        if let mime, !mime.isEmpty { body["mime"] = mime }
        if direct { body["delivered_direct"] = true }
        // A direct drop's record carries the receiver's own answer, so it's recorded as landed.
        if direct, let outcome { body["outcome"] = outcome.rawValue }
        return body
    }

    /// `POST /drops/upload?kind=…&target=…&name=…&mime=…&action=…&x=…&y=…` (body = the bytes).
    static func uploadPath(kind: HoloKind, target: String, name: String, mime: String,
                           action: HoloAction?, position: HoloPosition? = nil) -> String {
        var items = [URLQueryItem(name: "kind", value: kind.rawValue),
                     URLQueryItem(name: "target", value: target),
                     URLQueryItem(name: "name", value: name),
                     URLQueryItem(name: "mime", value: mime)]
        if let action { items.append(URLQueryItem(name: "action", value: action.rawValue)) }
        if let position {
            items.append(URLQueryItem(name: "x", value: fraction(position.x)))
            items.append(URLQueryItem(name: "y", value: fraction(position.y)))
        }
        var c = URLComponents()
        c.queryItems = items
        // URLComponents leaves "+" alone, which a server reads as a space.
        let query = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return base + "/drops/upload?" + query
    }

    static func fraction(_ v: Double) -> String {
        let s = String(format: "%.4f", v)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty ? "0" : t
    }

    static func landed(_ outcome: HoloOutcome, error: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["outcome": outcome.rawValue]
        if let error, !error.isEmpty { body["error"] = error }
        return body
    }

    static func lanAdvert(url: String, token: String, expires: Date) -> [String: Any] {
        ["url": url, "token": token, "expires": expires.timeIntervalSince1970.rounded()]
    }

    static func screenReport(width: Double, height: Double, scale: Double,
                             windows: [HoloWindowOutline]) -> [String: Any] {
        ["width": width, "height": height, "scale": scale, "windows": windows.map(\.json)]
    }

    /// The LAN receiver's `X-Holo-Meta`: the drop's fields as base64 JSON.
    static func meta(_ fields: [String: Any]) -> String {
        ((try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8))
            .base64EncodedString()
    }

    static func decodeMeta(_ header: String?) -> [String: Any]? {
        guard let header, let data = Data(base64Encoded: header.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A drop's fields for the LAN path (same names as the server's record).
    static func directFields(kind: HoloKind, name: String = "", mime: String = "", text: String? = nil,
                             url: String? = nil, title: String? = nil, action: HoloAction?,
                             position: HoloPosition? = nil, from: String = "", fromName: String = "") -> [String: Any] {
        var f: [String: Any] = ["kind": kind.rawValue]
        if !name.isEmpty { f["name"] = name }
        if !mime.isEmpty { f["mime"] = mime }
        if let text { f["text"] = text }
        if let url { f["url"] = url }
        if let title, !title.isEmpty { f["title"] = title }
        if let action { f["action"] = action.rawValue }
        if let position { f["position"] = position.json }
        if !from.isEmpty { f["from"] = from }
        if !fromName.isEmpty { f["from_name"] = fromName }
        return f
    }
}

/// One window on the Mac's screen map, as fractions of the display (top-left origin).
struct HoloWindowOutline: Equatable, Sendable {
    let x: Double, y: Double, w: Double, h: Double
    let app: String

    var json: [String: Any] {
        ["x": HoloGeometry.round4(x), "y": HoloGeometry.round4(y),
         "w": HoloGeometry.round4(w), "h": HoloGeometry.round4(h), "app": app]
    }
}

/// Screen geometry: where a drop lands, and the windows the sender's map draws.
enum HoloGeometry {
    static let cardSize = CGSize(width: 232, height: 244)

    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    /// The spot a drop is aimed at, in AppKit coordinates (origin bottom-left): `position` is
    /// a fraction of `visible` measured from its top-left; none means the middle.
    static func point(for position: HoloPosition?, in visible: CGRect) -> CGPoint {
        let p = position ?? HoloPosition(x: 0.5, y: 0.5)
        return CGPoint(x: visible.minX + p.x * visible.width, y: visible.maxY - p.y * visible.height)
    }

    /// The card's frame: centred on the aimed spot, kept wholly inside `visible`.
    static func cardFrame(position: HoloPosition?, visible: CGRect, size: CGSize = cardSize) -> CGRect {
        let c = point(for: position, in: visible)
        return centred(on: c, size: size, visible: visible)
    }

    /// A card already on screen at `frame`, resized to `size` about its centre (a picture
    /// arriving grows the card where it sits), kept wholly inside `visible`.
    static func refit(_ frame: CGRect, to size: CGSize, visible: CGRect) -> CGRect {
        centred(on: CGPoint(x: frame.midX, y: frame.midY), size: size, visible: visible)
    }

    private static func centred(on c: CGPoint, size: CGSize, visible: CGRect) -> CGRect {
        var x = c.x - size.width / 2
        var y = c.y - size.height / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A picture card is the picture: about the same area whatever its shape (a panorama
    /// weighs what a portrait does), at the picture's own aspect ratio. A shape too extreme
    /// for the box is cropped a little at the clamp, never letterboxed.
    static let heroArea: CGFloat = 320 * 240
    static let heroMin = CGSize(width: 220, height: 150)
    static let heroMax = CGSize(width: 360, height: 400)
    /// Link, text and file cards (no picture): this wide, as tall as their content.
    static let compactWidth: CGFloat = 360

    static func heroSize(aspect: CGFloat) -> CGSize {
        guard aspect.isFinite, aspect > 0 else { return CGSize(width: 320, height: 240) }
        var w = (heroArea * aspect).squareRoot()
        var h = w / aspect
        let down = min(1, heroMax.width / w, heroMax.height / h)
        w *= down
        h *= down
        w = min(max(w, heroMin.width), heroMax.width)
        h = min(max(h, heroMin.height), heroMax.height)
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// Windows from the window server (global top-left coordinates, front to back) as fractions
    /// of `display`, clipped to it. Off-display, tiny and nameless ones are left out.
    static func outlines(_ windows: [(bounds: CGRect, app: String)], display: CGRect,
                         minSide: CGFloat = 40, limit: Int = 30) -> [HoloWindowOutline] {
        guard display.width > 0, display.height > 0 else { return [] }
        var out: [HoloWindowOutline] = []
        for w in windows {
            let clipped = w.bounds.intersection(display)
            guard !clipped.isNull, clipped.width >= minSide, clipped.height >= minSide, !w.app.isEmpty else { continue }
            out.append(HoloWindowOutline(x: Double((clipped.minX - display.minX) / display.width),
                                         y: Double((clipped.minY - display.minY) / display.height),
                                         w: Double(clipped.width / display.width),
                                         h: Double(clipped.height / display.height), app: w.app))
            if out.count >= limit { break }
        }
        return out
    }
}

/// The Orbit popup's geometry: devices on a ring around the item, the nearest one lit, and a
/// fling's direction picking a device.
enum HoloOrbitLayout {
    /// The angle (degrees, 0 = up, clockwise) of each device on the ring: at its bearing when
    /// one is known, else spread evenly from the top.
    static func angles(_ devices: [HoloDevice]) -> [String: Double] {
        var out: [String: Double] = [:]
        let unknown = devices.filter { $0.bearing == nil }
        for d in devices { if let b = d.bearing { out[d.id] = normalise(b) } }
        let step = unknown.isEmpty ? 0 : 360.0 / Double(unknown.count)
        for (i, d) in unknown.enumerated() { out[d.id] = normalise(Double(i) * step) }
        return out
    }

    /// Centre of each bubble for a ring of `radius` around `centre` (SwiftUI coordinates, y down).
    static func positions(_ devices: [HoloDevice], centre: CGPoint, radius: CGFloat) -> [String: CGPoint] {
        angles(devices).mapValues { deg in
            let r = deg * .pi / 180
            return CGPoint(x: centre.x + radius * CGFloat(sin(r)), y: centre.y - radius * CGFloat(cos(r)))
        }
    }

    /// The device to light up: the closest by distance, else the surest bearing.
    static func nearest(_ devices: [HoloDevice]) -> HoloDevice? {
        if let d = devices.filter({ $0.distance != nil }).min(by: { $0.distance! < $1.distance! }) { return d }
        return devices.filter { $0.bearing != nil && $0.bearingConfidence > 0 }
            .max { $0.bearingConfidence < $1.bearingConfidence }
    }

    /// The device a fling points at: within `tolerance` degrees of the throw's direction
    /// (SwiftUI vector, y down), the closest in angle. A short drag throws nothing.
    static func target(for vector: CGVector, devices: [HoloDevice], tolerance: Double = 35,
                       minLength: CGFloat = 40) -> HoloDevice? {
        guard hypot(vector.dx, vector.dy) >= minLength else { return nil }
        let deg = normalise(atan2(Double(vector.dx), Double(-vector.dy)) * 180 / .pi)
        let a = angles(devices)
        return devices
            .compactMap { d -> (HoloDevice, Double)? in a[d.id].map { (d, gap(deg, $0)) } }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    static func normalise(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    static func gap(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalise(a) - normalise(b))
        return min(d, 360 - d)
    }
}

/// The direction beacons' codes, so the phone can tell this Mac's chirp or flash from any other.
///
/// Chirp v1: 48 kHz-independent FSK, 20 symbols × 15 ms = 300 ms; 18.5 kHz = 0, 19.5 kHz = 1;
/// preamble 1 0 1 0, then the 16 bits of `code16(nonce)` MSB first; 2 ms raised-cosine edges.
/// Flash v1: 15 frames at 10 Hz (1.5 s) of a full-screen white veil, bright (alpha 0.10) = 1,
/// clear = 0; preamble 1 0 1 0, then the low 11 bits of `code16(nonce)` MSB first.
enum HoloBeaconCode {
    static let chirpSymbol: TimeInterval = 0.015
    static let zeroHz: Double = 18_500
    static let oneHz: Double = 19_500
    static let flashHz: Double = 10
    static let preamble: [Bool] = [true, false, true, false]

    /// A nonce as 16 bits: a hex or decimal number's low bits, else FNV-1a of its UTF-8.
    static func code16(_ nonce: String) -> UInt16 {
        let t = nonce.trimmingCharacters(in: .whitespaces)
        if let n = UInt64(t) { return UInt16(truncatingIfNeeded: n) }
        if t.count <= 16, let n = UInt64(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16) {
            return UInt16(truncatingIfNeeded: n)
        }
        var h: UInt32 = 2_166_136_261
        for b in t.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return UInt16(truncatingIfNeeded: h)
    }

    static func chirpBits(_ nonce: String) -> [Bool] {
        let c = code16(nonce)
        return preamble + (0..<16).reversed().map { (c >> UInt16($0)) & 1 == 1 }
    }

    static func flashFrames(_ nonce: String) -> [Bool] {
        let c = code16(nonce)
        return preamble + (0..<11).reversed().map { (c >> UInt16($0)) & 1 == 1 }
    }
}

/// File names for what lands in ~/Downloads/Holo Drop.
enum HoloFiles {
    /// A name safe for the file system: no path separators or control characters, not hidden,
    /// not empty, at most 120 characters (the extension kept).
    static func safeName(_ raw: String, fallback: String = "Holo Drop") -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = fallback }
        if s.count > 120 {
            let ext = (s as NSString).pathExtension
            let stem = (s as NSString).deletingPathExtension
            s = String(stem.prefix(ext.isEmpty ? 120 : max(1, 119 - ext.count))) + (ext.isEmpty ? "" : "." + ext)
        }
        return s
    }

    /// `name`, or "name 2.ext", "name 3.ext"… — the first not in `taken`.
    static func unique(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 2...9_999 {
            let candidate = "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            if !taken(candidate) { return candidate }
        }
        return "\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
    }
}
