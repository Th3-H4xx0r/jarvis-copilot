import Foundation
import Observation
import WidgetKit

/// The Power integrations as this phone last heard them. Every screen and background
/// service that belongs to one asks `isOn(_:)`; anything unknown counts as on.
///
/// Fresh at launch and every foreground, and pushed by the server over the bridge
/// topic `power` whenever any switch flips (on any device, or by Jarvis). The off ids
/// go to the App Group (`PowerShared`) for the extensions.
@Observable
@MainActor
final class PowerState {
    static let shared = PowerState()

    private(set) var rows: [PowerRow] = []
    private(set) var offIDs: Set<String>
    /// Integrations whose switch-off is waiting for Face ID on this phone.
    private(set) var pending: Set<String> = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let fetch: () async throws -> [String: Any]
    @ObservationIgnored private let send: (String, [String: Any]) async throws -> [String: Any]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let showApprovals: () async -> Void
    @ObservationIgnored private var listeners: [(Set<String>) -> Void] = []
    @ObservationIgnored private var started = false
    private static let rowsKey = "power.rows.v1"

    init(fetch: (() async throws -> [String: Any])? = nil,
         send: ((String, [String: Any]) async throws -> [String: Any])? = nil,
         defaults: UserDefaults = PowerShared.defaults,
         showApprovals: (() async -> Void)? = nil) {
        let api = PowerAPI()
        self.fetch = fetch ?? { try await api.list() }
        self.send = send ?? { id, body in try await api.change(id, body: body) }
        self.defaults = defaults
        self.showApprovals = showApprovals ?? { await FaceIDApprovals.power.refresh() }
        offIDs = PowerShared.offIDs(defaults: defaults)
        if let data = defaults.data(forKey: Self.rowsKey),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            rows = list.compactMap(PowerRow.init(json:))
            hasLoaded = !rows.isEmpty
        }
    }

    func isOn(_ id: String) -> Bool { !offIDs.contains(id) }

    func row(_ id: String) -> PowerRow? { rows.first { $0.id == id } }

    /// Runs `listener` with the off ids now and after every change (background services
    /// start and stop from here).
    func observe(_ listener: @escaping (Set<String>) -> Void) {
        listeners.append(listener)
        listener(offIDs)
    }

    /// Wire the bridge topic and fetch once. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        BridgeTopics.shared.on("power") { _ in Task { await PowerState.shared.refresh() } }
        BridgeTopics.shared.onResync { Task { await PowerState.shared.refresh() } }
        BridgeTopics.shared.want("power", owner: "power")
        Task { await refresh() }
    }

    func refresh() async {
        do {
            let body = try await fetch()
            apply(list: body["integrations"] as? [[String: Any]] ?? [])
            errorMessage = nil
        } catch {
            // Keep what we had: a failed fetch never hides or shows anything new.
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }

    func apply(list: [[String: Any]]) {
        let parsed = list.compactMap(PowerRow.init(json:))
        rows = parsed
        hasLoaded = true
        if JSONSerialization.isValidJSONObject(list),
           let data = try? JSONSerialization.data(withJSONObject: list) {
            defaults.set(data, forKey: Self.rowsKey)
        }
        let off = Set(parsed.filter { !$0.enabled }.map(\.id))
        pending.subtract(off)
        guard off != offIDs else { return }
        offIDs = off
        PowerShared.store(offIDs: off, defaults: defaults)
        WidgetCenter.shared.reloadAllTimelines()
        for listener in listeners { listener(off) }
    }

    func set(_ id: String, enabled: Bool) async -> PowerSetResult {
        await change(id, body: ["enabled": enabled])
    }

    func setSettings(_ id: String, _ changes: [String: Any]) async -> PowerSetResult {
        await change(id, body: ["settings": changes])
    }

    private func change(_ id: String, body: [String: Any]) async -> PowerSetResult {
        do {
            let reply = try await send(id, body)
            if reply["pending"] != nil {
                pending.insert(id)
                await showApprovals()
                return .pending
            }
            if reply["ok"] as? Bool == false {
                return .failed(reply["error"] as? String ?? "That didn't work")
            }
            await refresh()
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
