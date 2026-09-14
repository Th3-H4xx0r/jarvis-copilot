import Foundation
import Observation

/// Paired Jarvis Balls, their live status, and the settings the ball page edits.
@Observable
@MainActor
final class JarvisBallStore {
    static let shared = JarvisBallStore()

    private(set) var balls: [JarvisBallDevice] = []
    private(set) var statuses: [String: JarvisBallStatus] = [:]
    private(set) var settings: [String: JarvisBallSettings] = [:]
    private(set) var homes: [String: [JarvisBallHome]] = [:]
    private(set) var error: String?

    private let api: JarvisBallAPI
    private var lastRefresh = Date.distantPast

    init(api: JarvisBallAPI = JarvisBallAPI()) {
        self.api = api
    }

    /// The same "connected" the other wearable cards and the wearables skills use: a live link.
    var rosterEntries: [WearableEntry] {
        balls.map {
            WearableEntry(kind: "jarvis_ball", deviceID: $0.id, model: "Jarvis Ball", name: $0.name,
                          connected: $0.bridgeConnected, rssi: nil, lastRSSI: statuses[$0.id]?.rssi,
                          lastSeen: $0.lastSeen, listed: true)
        }
    }

    func refresh(force: Bool = false) async {
        guard BridgeClient.shared.isPaired else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 15 else { return }
        lastRefresh = Date()
        do {
            balls = try await api.balls()
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        for ball in balls where ball.bridgeConnected {
            if let status = try? await api.status(ball.id) { statuses[ball.id] = status }
        }
    }

    /// While a screen showing balls is on screen.
    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh(force: true)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    /// Settings + homes for the ball page; also brings the ball's theme and clock in line with the phone.
    func loadDetail(_ id: String) async {
        do {
            var s = try await api.settings(id)
            homes[id] = try await api.homes(id)
            var sync: [String: Any] = [:]
            if s.accent != JarvisBallLook.hex(JcAccent.hex) { sync["theme"] = JarvisBallLook.theme }
            let tz = TimeZone.current
            if s.timezone != tz.identifier || s.tzPosix != JarvisBallLook.posixTZ(tz) {
                sync["timezone"] = tz.identifier
                sync["tz_posix"] = JarvisBallLook.posixTZ(tz)
            }
            if !sync.isEmpty { s = try await api.setSettings(id, sync) }
            settings[id] = s
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func update(_ id: String, _ changes: [String: Any]) async {
        do {
            settings[id] = try await api.setSettings(id, changes)
            if let status = try? await api.status(id) { statuses[id] = status }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteHome(_ id: String, home: String) async {
        do {
            try await api.deleteHome(id, home: home)
            await loadDetail(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reboot(_ id: String) async {
        do {
            try await api.reboot(id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
