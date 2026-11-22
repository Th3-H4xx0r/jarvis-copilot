import Foundation

/// Whether this Mac should be asking the iPhone for the glasses' video right now: while an
/// app (FaceTime, Zoom, Meet) is using the Jarvis Glasses camera, and a little after, so
/// switching cameras or rejoining a call doesn't tear the connection down. Pure: tested.
struct GlassesCameraDemand {
    static let linger: TimeInterval = 15

    private(set) var lastInUse: Date?

    /// `clients`: apps using the camera; nil when the extension can't say (then ask while
    /// it's installed — more traffic, but the camera still works).
    mutating func wanted(installed: Bool, clients: Int?, now: Date) -> Bool {
        guard installed else {
            lastInUse = nil
            return false
        }
        if clients.map({ $0 > 0 }) ?? true {
            lastInUse = now
            return true
        }
        guard let last = lastInUse else { return false }
        return now.timeIntervalSince(last) < Self.linger
    }
}

/// What the Mac's Jarvis Glasses camera is doing, for Settings.
enum GlassesCameraPhase: Equatable {
    case notInstalled
    case idle
    case offline
    case waitingForPhone
    case connecting
    case connected
    case live

    static func of(installed: Bool, wanted: Bool, online: Bool, asked: Bool,
                   peer: GlassesCameraPeer.State?, frameFresh: Bool) -> GlassesCameraPhase {
        guard installed else { return .notInstalled }
        guard wanted else { return .idle }
        guard online else { return .offline }
        guard asked else { return .connecting }
        switch peer {
        case nil, .failed?, .disconnected?: return .waitingForPhone
        case .connecting?: return .connecting
        case .connected?: return frameFresh ? .live : .connected
        }
    }

    var text: String {
        switch self {
        case .notInstalled: return "Not installed yet."
        case .idle: return "Ready. Pick “Jarvis Glasses” as the camera in FaceTime, Zoom or Meet."
        case .offline: return "An app is using the camera, but Jarvis isn't connected to your server."
        case .waitingForPhone:
            return "An app is using the camera. On your iPhone: Meta glasses → Watch live → Send to Mac camera."
        case .connecting: return "Connecting to your iPhone…"
        case .connected: return "Connected to your iPhone. Waiting for the glasses' video…"
        case .live: return "Showing your glasses' live video."
        }
    }
}
