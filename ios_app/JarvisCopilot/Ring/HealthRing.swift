import Foundation

/// Which ring leads Jarvis Health. Pranav picks it in Health settings. Both rings keep syncing,
/// pushing their days and staying linked on the server, so switching never hides history — the
/// server merges each day from the primary first and fills the rest from the other ring. The
/// choice also picks which ring's spot checks the Health tab offers and which one Apple Health
/// gets its days from (from the switch on, so no day is written twice).
enum HealthRing: String, CaseIterable, Identifiable {
    case r12 = "ring"
    case x5 = "x5ring"
    case band = "band"

    static let key = "jc.health.ring"

    var id: String { rawValue }
    /// The roster kind, `WearableKeepAlive.ring` or `.x5ring`.
    var kind: String { rawValue }

    var label: String {
        switch self {
        case .r12: return ColmiR12.model
        case .x5: return X5Ring.model
        case .band: return BandDevice.model
        }
    }

    /// The choice, or — before one is made — the R12 if it is paired, else the X5 if it is.
    static func current(defaults: UserDefaults = .standard) -> HealthRing {
        if let raw = defaults.string(forKey: key), let chosen = HealthRing(rawValue: raw) { return chosen }
        if WearableIdentity.remembered(WearableKeepAlive.ring, defaults: defaults) != nil { return .r12 }
        if WearableIdentity.remembered(WearableKeepAlive.x5ring, defaults: defaults) != nil { return .x5 }
        if WearableIdentity.remembered(WearableKeepAlive.band, defaults: defaults) != nil { return .band }
        return .r12
    }

    static var current: HealthRing { current() }

    static func set(_ ring: HealthRing, defaults: UserDefaults = .standard) {
        defaults.set(ring.rawValue, forKey: key)
    }

    static let sinceKey = "jc.health.ring.since"

    /// The day the current ring took over, if it was switched: Apple Health gets its days from
    /// then on, so the two rings never both write a day.
    static func since(defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: sinceKey) }

    /// Whether there is a choice to make: two or more of the R12, the X5 and the band are paired.
    static func bothPaired(defaults: UserDefaults = .standard) -> Bool {
        allCases.filter { WearableIdentity.remembered($0.kind, defaults: defaults) != nil }.count >= 2
    }

    /// What registration tells the server about a ring once two are paired: the chosen one is
    /// linked and primary. The others say nothing about linking — whether one is on is the
    /// person's switch in Health settings, and re-registering on every launch used to switch a
    /// wearable they had turned off back on.
    static func serverFlags(for kind: String, chosen: HealthRing) -> [String: Any] {
        kind == chosen.kind ? ["linked": true, "primary": true] : ["primary": false]
    }

    /// The ring a server device key names (`band-1a2b3c4d` → the band).
    static func ring(forDeviceKey key: String) -> HealthRing? {
        key.split(separator: "-").first.flatMap { HealthRing(rawValue: String($0)) }
    }

    /// Takes on a primary chosen elsewhere (Health settings' sources, the web) without
    /// re-registering: the server already has it.
    static func adopt(_ ring: HealthRing, defaults: UserDefaults = .standard) {
        guard ring != current(defaults: defaults) else { return }
        set(ring, defaults: defaults)
        defaults.set(RingDates.dayKey(Date()), forKey: sinceKey)
        NotificationCenter.default.post(name: .jcHealthRingChanged, object: nil)
    }

    /// The chosen ring's history.
    @MainActor static var store: RingHistoryStore? {
        switch current {
        case .r12: return WearablesHub.shared.ring.store
        case .x5: return WearablesHub.shared.x5.store
        case .band: return WearablesHub.shared.band.store
        }
    }

    /// Makes `ring` the primary: re-registers, and sends the new ring's recent days in case some
    /// never reached the server.
    @MainActor static func choose(_ ring: HealthRing) {
        guard ring != current else { return }
        set(ring)
        UserDefaults.standard.set(RingDates.dayKey(Date()), forKey: sinceKey)
        WearablesHub.shared.registerHealthIntegrations()
        let x5 = WearablesHub.shared.x5, band = WearablesHub.shared.band
        if let store = x5.store { Task { await x5.pushHealthDays(Set(store.allKeys().suffix(14))) } }
        if let store = band.store { Task { await band.pushHealthDays(Set(store.allKeys().suffix(14))) } }
        NotificationCenter.default.post(name: .jcHealthRingChanged, object: nil)
    }
}

extension Notification.Name {
    static let jcHealthRingChanged = Notification.Name("jcHealthRingChanged")
}

extension AppleHealthPlan {
    /// The R12's sample ids stay exactly as they always were — changing them would write its whole
    /// history again — and the X5's carry their own prefix, so the two never overwrite each other.
    static func tagged(_ samples: [AppleHealthSample], ring: HealthRing) -> [AppleHealthSample] {
        guard ring != .r12 else { return samples }
        return samples.map { sample in
            var tagged = sample
            tagged.syncID = (ring == .band ? "band-" : "x5-") + sample.syncID
            return tagged
        }
    }
}
