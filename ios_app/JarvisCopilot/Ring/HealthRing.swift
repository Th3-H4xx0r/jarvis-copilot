import Foundation

/// Which ring Jarvis Health reads. Pranav picks it in Health settings; both rings keep syncing
/// their own history either way, but only this one is registered with the server, pushed, shown
/// in the Health tab and exported to Apple Health.
enum HealthRing: String, CaseIterable, Identifiable {
    case r12 = "ring"
    case x5 = "x5ring"

    static let key = "jc.health.ring"

    var id: String { rawValue }
    /// The roster kind, `WearableKeepAlive.ring` or `.x5ring`.
    var kind: String { rawValue }

    var label: String {
        switch self {
        case .r12: return ColmiR12.model
        case .x5: return X5Ring.model
        }
    }

    /// The choice, or — before one is made — the R12 if it is paired, else the X5 if it is.
    static func current(defaults: UserDefaults = .standard) -> HealthRing {
        if let raw = defaults.string(forKey: key), let chosen = HealthRing(rawValue: raw) { return chosen }
        if WearableIdentity.remembered(WearableKeepAlive.ring, defaults: defaults) != nil { return .r12 }
        if WearableIdentity.remembered(WearableKeepAlive.x5ring, defaults: defaults) != nil { return .x5 }
        return .r12
    }

    static var current: HealthRing { current() }

    static func set(_ ring: HealthRing, defaults: UserDefaults = .standard) {
        defaults.set(ring.rawValue, forKey: key)
    }

    /// Whether there is a choice to make.
    static func bothPaired(defaults: UserDefaults = .standard) -> Bool {
        WearableIdentity.remembered(WearableKeepAlive.ring, defaults: defaults) != nil
            && WearableIdentity.remembered(WearableKeepAlive.x5ring, defaults: defaults) != nil
    }

    /// The kinds registered with Jarvis Health: the chosen ring, and the scale.
    static func eligibleKinds(chosen: HealthRing) -> Set<String> {
        [chosen.kind, WearableKeepAlive.scale]
    }

    /// The chosen ring's history.
    @MainActor static var store: RingHistoryStore? {
        switch current {
        case .r12: return WearablesHub.shared.ring.store
        case .x5: return WearablesHub.shared.x5.store
        }
    }

    /// Switches Jarvis Health to `ring`: re-registers, and sends the new ring's recent days.
    @MainActor static func choose(_ ring: HealthRing) {
        guard ring != current else { return }
        set(ring)
        WearablesHub.shared.registerHealthIntegrations()
        if ring == .x5, let store = WearablesHub.shared.x5.store {
            Task { await X5HealthPush.push(Set(store.allKeys().suffix(14)), manager: WearablesHub.shared.x5) }
        }
        NotificationCenter.default.post(name: .jcHealthRingChanged, object: nil)
    }
}

extension Notification.Name {
    static let jcHealthRingChanged = Notification.Name("jcHealthRingChanged")
}

/// Sends X5 days to Jarvis Health after a sync, when the X5 is its ring — the X5's side of
/// what `RingSync.pushDays` does for the R12.
enum X5HealthPush {
    @MainActor
    @discardableResult
    static func push(_ keys: Set<String>, manager: X5Manager) async -> Bool {
        guard HealthRing.current == .x5, let deviceID = manager.deviceID, let store = manager.store, !keys.isEmpty else {
            return false
        }
        let client = HealthClient(spaceID: HealthSpace.id(forRing: deviceID))
        for key in keys.sorted() {
            let day = store.day(key)
            guard day.syncedAt != nil else { continue }
            do {
                try await client.pushDay(HealthDayPayload.make(day, key: key, deviceID: deviceID,
                                                               source: WearableKeepAlive.x5ring,
                                                               battery: manager.session.battery))
            } catch {
                JcLog.devices.notice("x5: could not push \(key, privacy: .public) to the server")
                return false
            }
        }
        return true
    }
}

extension AppleHealthPlan {
    /// The R12's sample ids stay exactly as they always were — changing them would write its whole
    /// history again — and the X5's carry their own prefix, so the two never overwrite each other.
    static func tagged(_ samples: [AppleHealthSample], ring: HealthRing) -> [AppleHealthSample] {
        guard ring == .x5 else { return samples }
        return samples.map { sample in
            var tagged = sample
            tagged.syncID = "x5-" + sample.syncID
            return tagged
        }
    }
}
