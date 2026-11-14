import SwiftUI

/// Where the phone hides or stops what belongs to a switched-off Power integration.
/// The full map of places is `jarvis_power/surfaces.py` on the server.

extension AppTab {
    /// The tabs to show: Health goes while Jarvis Health is off.
    @MainActor static var visible: [AppTab] {
        allCases.filter { $0 != .health || PowerState.shared.isOn("jarvis-health") }
    }

    /// The same count from the App Group cache, for layout code outside the main actor.
    static var visibleCount: Int {
        allCases.count - (PowerShared.isOn("jarvis-health") ? 0 : 1)
    }
}

extension MoreDestination {
    /// The Power integration a More tile belongs to, if any.
    var powerID: String? {
        switch self {
        case .kanban: return "kanban"
        case .security: return "security-advisor"
        case .islandDesigns: return "island-designs"
        case .photon: return "photon"
        default: return nil
        }
    }

    @MainActor static var visible: [MoreDestination] {
        allCases.filter { $0.powerID.map(PowerState.shared.isOn) ?? true }
    }
}

/// Push categories that belong to a Power integration: dropped while it's off.
enum PowerPush {
    static let categories = ["IMESSAGE_FACTS": "imessage-memory", "SECURITY_ALERT": "security-advisor"]

    static func suppressed(category: String, offIDs: Set<String> = PowerShared.offIDs()) -> Bool {
        guard let id = categories[category] else { return false }
        return offIDs.contains(id)
    }
}

@MainActor
enum PowerGates {
    private static var started: Set<String> = []

    /// Runs `start` once, the first time `id` is on — now, or when it's switched on later.
    /// (Services without a stop: switching off stops them at the next launch; the server
    /// refuses their calls meanwhile.)
    /// Starts a service while `id` is on and stops it when it's switched off (and again on).
    static func follow(_ id: String, start: @escaping @MainActor () -> Void,
                       stop: @escaping @MainActor () -> Void) {
        var running = false
        PowerState.shared.observe { off in
            let on = !off.contains(id)
            if on, !running { running = true; start() }
            if !on, running { running = false; stop() }
        }
    }

    static func whenOn(_ id: String, _ start: @escaping @MainActor () -> Void) {
        PowerState.shared.observe { off in
            guard !off.contains(id), !started.contains(id) else { return }
            started.insert(id)
            start()
        }
    }
}

private struct PowerGated: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        if PowerState.shared.isOn(id) { content }
    }
}

extension View {
    /// Hidden while the Power integration `id` is switched off.
    func powerGated(_ id: String) -> some View { modifier(PowerGated(id: id)) }
}
