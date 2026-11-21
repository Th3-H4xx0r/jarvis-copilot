import AppKit
import Foundation

/// Game Streaming on the Mac: the Power switch as last read from `/api/power`, so
/// the menu offers "Stream to this Mac…" only while it's on. The Mac's native
/// Power presence is this menu entry; the full card and page live on the iPhone
/// and the dashboard (the Mac is a stream target, driven by jc-client). Mirrors
/// `HoloDrop`. Unknown counts as on; a server without Game Streaming is off.
@MainActor
@Observable
final class GameStreaming {
    static let shared = GameStreaming()

    /// The switch as last read. Cached so the menu is right the instant it opens.
    private(set) var on: Bool = GameStreaming.isOnCached

    nonisolated static var isOnCached: Bool {
        UserDefaults.standard.object(forKey: "gameStreaming.on") as? Bool ?? true
    }

    @ObservationIgnored private var started = false

    /// Read the switch once at launch.
    func start() {
        guard !started, !AppDelegate.isTesting else { return }
        started = true
        Task { await refreshPower() }
    }

    /// The server published `power` (any integration switched): re-read the switch.
    func powerTopic() { Task { await refreshPower() } }

    func refreshPower() async {
        guard let origin = AppModel.shared.apiOrigin, let url = URL(string: origin + "/api/power") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Jarvis-Mac/1 game-streaming", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            set(on: Self.isOn(inPower: reply) ?? false)   // no row: this server has none
        } catch {
            // unreachable or unreadable: keep what we had (unknown counts as on)
        }
    }

    /// Whether the `game-streaming` row in a `/api/power` reply is on; nil when the
    /// server has no such row. Pure, for the tests.
    nonisolated static func isOn(inPower reply: [String: Any]) -> Bool? {
        let rows = reply["integrations"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { ($0["id"] as? String) == "game-streaming" }) else { return nil }
        return row["enabled"] == nil ? true : (row["enabled"] as? Bool ?? true)
    }

    private func set(on new: Bool) {
        UserDefaults.standard.set(new, forKey: "gameStreaming.on")
        guard new != on else { return }
        on = new
        NSLog("Jarvis: Game Streaming is \(new ? "on" : "off")")
    }
}
