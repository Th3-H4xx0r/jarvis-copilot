import Foundation

/// Sends the scale's weigh-ins to Jarvis Health: each once, the owner's only
/// (a shared scale's other profiles stay on the phone), and whatever the
/// server could not take waits for the next weigh-in or Health refresh. The
/// first run sends the whole history the phone kept.
@MainActor
enum ScaleUploader {
    private static let sentKey = "jc.scale.sentReadings"
    private static var flushing: Task<Void, Never>?

    /// Readings not yet sent, from the active profile (or with none).
    static func unsent(_ store: ScaleHistoryStore = .shared, sent: Set<String>? = nil) -> [ScaleReading] {
        let sent = sent ?? sentIDs()
        let owner = store.activeProfile?.id
        return store.readings.filter { reading in
            !sent.contains(reading.id.uuidString) && (reading.profileID == nil || owner == nil || reading.profileID == owner)
        }
    }

    static func flush(client: HealthClient = HealthClient(spaceID: HealthSpace.shared),
                      store: ScaleHistoryStore = .shared) async {
        if let flushing { return await flushing.value }
        let task = Task { @MainActor in
            // Filed under the scale Jarvis Health knows, the one in the roster.
            guard let deviceID = WearableIdentity.remembered(WearableKeepAlive.scale) else { return }
            let pending = unsent(store)
            for start in stride(from: 0, to: pending.count, by: 100) {
                let chunk = Array(pending[start..<min(start + 100, pending.count)])
                do {
                    try await client.pushWeights(chunk.map(payload), deviceID: deviceID)
                    markSent(chunk.map(\.id.uuidString))
                } catch {
                    JcLog.dropped(JcLog.devices, "weigh-ins to Jarvis Health", error)
                    return
                }
            }
        }
        flushing = task
        await task.value
        flushing = nil
    }

    /// One weigh-in in the server's shape.
    static func payload(_ reading: ScaleReading) -> [String: Any] {
        var out: [String: Any] = ["id": reading.id.uuidString.lowercased(),
                                  "at": HealthClient.instant.string(from: reading.date),
                                  "weight_kg": reading.weightKg]
        let extras: [(BodyMetric, String)] = [(.bmi, "bmi"), (.bodyFat, "body_fat"), (.muscleMass, "muscle_mass"),
                                              (.bodyWater, "body_water"), (.boneMass, "bone_mass"),
                                              (.visceralFat, "visceral_fat"), (.bmr, "bmr")]
        for (metric, key) in extras {
            if let value = reading.metrics[metric] { out[key] = value }
        }
        return out
    }

    private static func sentIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
    }

    private static func markSent(_ ids: [String]) {
        UserDefaults.standard.set(Array(sentIDs().union(ids)), forKey: sentKey)
    }
}
