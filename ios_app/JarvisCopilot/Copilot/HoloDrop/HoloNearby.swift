import Foundation
import NearbyInteraction
import simd

/// UWB (Nearby Interaction) with other iPhones/iPads that have Jarvis open: each side's
/// discovery token travels through Jarvis (`beacon` mode `ni_token`), then the chips measure
/// distance and — when the phones can — direction.
@MainActor
final class HoloNearby: NSObject {
    static let shared = HoloNearby()

    /// (device, distance m, azimuth degrees right of where this phone points, or nil).
    var onReading: (String, Double?, Double?) -> Void = { _, _, _ in }
    private var sessions: [String: NISession] = [:]

    static var supported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }

    /// Offer our token to `device` (it answers with its own when its app is open).
    func reach(_ device: String, send: @escaping (String, String, String) async -> Void) {
        guard Self.supported, let token = session(for: device).discoveryToken.flatMap(Self.encode) else { return }
        Task { await send(device, "ni", token) }
    }

    /// A peer's token arrived: measure; answer with ours unless this was the answer.
    func peerToken(from device: String, token: String, nonce: String,
                   send: @escaping (String, String, String) async -> Void) {
        guard Self.supported, let peer = Self.decode(token) else { return }
        let s = session(for: device)
        s.run(NINearbyPeerConfiguration(peerToken: peer))
        if nonce != "ni-reply", let mine = s.discoveryToken.flatMap(Self.encode) {
            Task { await send(device, "ni-reply", mine) }
        }
    }

    func stop() {
        sessions.values.forEach { $0.invalidate() }
        sessions = [:]
    }

    private func session(for device: String) -> NISession {
        if let s = sessions[device] { return s }
        let s = NISession()
        s.delegate = self
        sessions[device] = s
        return s
    }

    fileprivate func device(of session: NISession) -> String? { sessions.first { $0.value === session }?.key }

    fileprivate func forget(_ device: String) { sessions[device] = nil }

    static func encode(_ token: NIDiscoveryToken) -> String? {
        (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true))?.base64EncodedString()
    }

    static func decode(_ b64: String) -> NIDiscoveryToken? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data)
    }

    /// Apple's convention: x to the right, so azimuth = asin(x).
    nonisolated static func azimuthDeg(_ direction: simd_float3) -> Double {
        Double(asin(max(-1, min(1, direction.x)))) * 180 / .pi
    }
}

extension HoloNearby: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let o = nearbyObjects.first else { return }
        let distance = o.distance.map(Double.init)
        let azimuth = o.direction.map(HoloNearby.azimuthDeg)
        Task { @MainActor in
            guard let device = HoloNearby.shared.device(of: session) else { return }
            HoloNearby.shared.onReading(device, distance, azimuth)
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor in
            if let device = HoloNearby.shared.device(of: session) { HoloNearby.shared.forget(device) }
        }
    }
}
