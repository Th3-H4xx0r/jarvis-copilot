import CoreGraphics
import Foundation

/// The phone's side of the Mac's "Jarvis Glasses" camera, as a pure state machine (tested).
///
/// The phone sends the glasses' live video to a Mac only when all three hold: he turned on
/// "Send to Mac camera", the glasses are live streaming (frames are arriving), and a Mac has
/// asked for it — the Mac app opens a "glasses" share on the Jarvis server while FaceTime, Zoom
/// or Meet is using its Jarvis Glasses camera. `decide` says what to do about the connection.
struct GlassesMacCameraMachine: Equatable {
    enum Phase: Equatable {
        case off
        case waitingForGlasses
        case waitingForMac
        case connecting
        case sending
        case failed(String)

        var text: String {
            switch self {
            case .off: return "Off"
            case .waitingForGlasses: return "Starts when the glasses go live."
            case .waitingForMac: return "Waiting for your computer. Pick “Jarvis Glasses” as the camera in FaceTime, Zoom, Meet or Teams."
            case .connecting: return "Connecting to your computer…"
            case .sending: return "On your computer's Jarvis Glasses camera."
            case .failed(let why): return "\(why) Trying again…"
            }
        }
    }

    enum Action: Equatable { case none, connect(String), disconnect }

    /// No frame for this long: the glasses aren't live any more.
    static let liveTimeout: TimeInterval = 3
    /// After a failed connection, wait this long before trying the same request again.
    static let retryDelay: TimeInterval = 5

    var enabled = false
    var glassesLive = false
    /// The Mac's newest "glasses" share (its request), nil when no Mac is asking.
    var request: String?
    /// The share the phone's connection is for.
    private(set) var connectedTo: String?
    private(set) var peerUp = false
    private(set) var failure: String?
    private(set) var retryAfter: Date?

    var phase: Phase {
        guard enabled else { return .off }
        guard glassesLive else { return .waitingForGlasses }
        if connectedTo != nil { return peerUp ? .sending : .connecting }
        if let failure { return .failed(failure) }
        return request == nil ? .waitingForMac : .connecting
    }

    /// One step: drop a connection nobody wants any more, or open the one that's wanted.
    mutating func decide(now: Date) -> Action {
        let wanted = enabled && glassesLive ? request : nil
        if let current = connectedTo, current != wanted {
            connectedTo = nil
            peerUp = false
            return .disconnect
        }
        guard let wanted, connectedTo == nil else { return .none }
        if let retryAfter, now < retryAfter { return .none }
        connectedTo = wanted
        peerUp = false
        failure = nil
        retryAfter = nil
        return .connect(wanted)
    }

    mutating func connected() {
        guard connectedTo != nil else { return }
        peerUp = true
        failure = nil
    }

    /// The connection broke: try again after `retryDelay` if the Mac still asks.
    mutating func failed(_ why: String, now: Date) {
        connectedTo = nil
        peerUp = false
        failure = why
        retryAfter = now.addingTimeInterval(Self.retryDelay)
    }

    /// The Mac ended the request (its app closed the camera): wait for a new one.
    mutating func ended() {
        connectedTo = nil
        peerUp = false
        request = nil
    }

    /// The newest open "glasses" share in the server's active list.
    static func newestRequest(in shares: [[String: Any]]) -> String? {
        shares
            .filter { $0["reason"] as? String == "glasses" && $0["status"] as? String != "ended" }
            .max { ($0["created_at"] as? String ?? "") < ($1["created_at"] as? String ?? "") }
            .flatMap { $0["id"] as? String }
    }

    /// `source` fitted inside `target`, aspect kept, centred, whole and even pixels.
    static func fit(_ source: CGSize, in target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, target.width >= 2, target.height >= 2 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = min(target.width / source.width, target.height / source.height)
        func even(_ v: CGFloat, max limit: CGFloat) -> CGFloat { min(limit, max(2, (v.rounded() / 2).rounded(.down) * 2)) }
        let w = even(source.width * scale, max: target.width), h = even(source.height * scale, max: target.height)
        return CGRect(x: ((target.width - w) / 2).rounded(.down), y: ((target.height - h) / 2).rounded(.down), width: w, height: h)
    }
}
