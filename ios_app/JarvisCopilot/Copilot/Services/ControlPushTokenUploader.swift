import Foundation
import WidgetKit

/// Sends Control Center's refresh-push tokens (`ControlPushTokens`) to the server when they change
/// (`POST /api/live/control-tokens {tokens}`), and again once a day in case it lost them. Run on
/// launch and every return to the foreground (`AppServices`).
@MainActor
final class ControlPushTokenUploader {
    static let shared = ControlPushTokenUploader()

    static let sentKey = "jc.controlPushTokens.sent"
    static let sentAtKey = "jc.controlPushTokens.sentAt"
    static let resendAfter: TimeInterval = 24 * 3600

    private let defaults: UserDefaults
    private let tokens: @MainActor @Sendable () async -> [String]
    private let post: @MainActor @Sendable ([String]) async -> Bool
    private var inFlight = false

    init(defaults: UserDefaults = ControlPushTokens.defaults,
         tokens: (@MainActor @Sendable () async -> [String])? = nil,
         post: (@MainActor @Sendable ([String]) async -> Bool)? = nil) {
        self.defaults = defaults
        self.tokens = tokens ?? Self.currentTokens
        self.post = post ?? Self.send
    }

    func uploadIfChanged(now: Date = Date()) async {
        guard !inFlight else { return }
        let current = ControlPushTokens.normalized(await tokens())
        let signature = current.joined(separator: ",")
        let sent = defaults.string(forKey: Self.sentKey)
        let fresh = now.timeIntervalSince1970 - defaults.double(forKey: Self.sentAtKey) < Self.resendAfter
        // Nothing new; or nothing at all and nothing ever sent.
        if sent == signature && fresh { return }
        if sent == nil && current.isEmpty { return }
        inFlight = true
        defer { inFlight = false }
        guard await post(current) else { return }
        defaults.set(signature, forKey: Self.sentKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.sentAtKey)
    }

    /// What iOS says now (the app may ask too), else what the widget filed.
    private static let currentTokens: @MainActor @Sendable () async -> [String] = {
        if #available(iOS 18.0, *),
           let controls = try? await ControlCenter.shared.currentControls() {
            let live = controls.compactMap { $0.pushInfo?.token }.map(ControlPushTokens.hex)
            if !live.isEmpty {
                ControlPushTokens.save(hex: live)
                return live
            }
        }
        return ControlPushTokens.load()
    }

    private static let send: @MainActor @Sendable ([String]) async -> Bool = { tokens in
        do {
            _ = try await JarvisAPI.shared.post("/api/live/control-tokens", json: ["tokens": tokens])
            return true
        } catch {
            JcLog.dropped(JcLog.services, "control push tokens", error)
            return false
        }
    }
}
