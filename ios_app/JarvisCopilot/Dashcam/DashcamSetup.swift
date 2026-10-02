import Foundation

/// The camera the phone was set up with. Stored in UserDefaults; the Wi‑Fi password lives in the
/// Keychain. One camera — Pranav has one car.
struct DashcamSetup: Codable, Equatable, Sendable {
    var ssid: String
    var family: DashcamFamily
    var cameraID: String
    var model: String = ""
    var brand: String = ""
    var firmware: String = ""
    var lenses: Int = 1
    /// A non-default camera address (`host[:port]`); nil = the family's usual address.
    var host: String? = nil
    /// Learned on the first sync: the camera refuses to list files outside playback mode, so
    /// syncs wait until the car is parked (playback mode can pause recording).
    var listingNeedsPlayback: Bool = false

    var deviceID: String { "dashcam-" + (cameraID.isEmpty ? ssid : cameraID) }
    var displayName: String {
        let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Dashcam" : name
    }

    func base() -> URL? {
        if let host, !host.isEmpty { return URL(string: "http://" + host) }
        return DashcamDetect.candidates.first { $0.family == family }.flatMap { URL(string: "http://" + $0.host) }
    }
}

enum DashcamSetupStore {
    static let key = "jc.dashcam.setup"
    static let passwordAccount = "dashcamWiFiPassword"
    /// Simulator / fake-camera override: when set, the camera at this host counts as joined.
    static let debugHostKey = "jc.dashcam.debugHost"

    static func load(_ defaults: UserDefaults = .standard) -> DashcamSetup? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DashcamSetup.self, from: data)
    }

    static func save(_ setup: DashcamSetup?, defaults: UserDefaults = .standard) {
        guard let setup, let data = try? JSONEncoder().encode(setup) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    static var password: String? {
        get { Keychain.read(passwordAccount) }
        set { Keychain.write(passwordAccount, newValue) }
    }

    static func debugHost(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: debugHostKey).flatMap { $0.isEmpty ? nil : $0 }
    }
}
