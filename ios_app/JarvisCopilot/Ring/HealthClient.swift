import Foundation

/// The phone's side of wearable health: read what the server computed, push the
/// days it collected, and edit the settings this screen owns.
///
/// Nothing here scores anything. The server does that, in one place, so the
/// phone and the web UI can never disagree about a number.
struct HealthClient {
    /// The source every settings write declares: the Health tab. The server
    /// refuses any other.
    static let settingsSource = "health-settings"

    let api: JarvisAPI
    let spaceID: String

    init(api: JarvisAPI = .shared, spaceID: String) {
        self.api = api
        self.spaceID = spaceID
    }

    private var base: String { "/api/integrations/\(spaceID)/health" }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return HealthClient.instant.date(from: text) ?? Date()
        }
        return d
    }()

    /// The server's one timestamp format: UTC, `Z`-suffixed.
    static let instant: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Every wearable feeding Jarvis Health, linked or not.
    static func devices(api: JarvisAPI = .shared) async throws -> [HealthRosterDevice] {
        let response = try await api.get("/api/health/devices")
        let raw = try response.object()["devices"] ?? []
        return try decode([HealthRosterDevice].self, from: raw)
    }

    /// Everything since the last wake.
    func now() async throws -> HealthNow {
        try Self.decode(HealthNow.self, from: try await api.get("\(base)/now").object())
    }

    /// One calendar day, merged across linked wearables.
    func day(_ date: String) async throws -> HealthDayResponse {
        // A query parameter, not part of the path: a "?" written into the path
        // is percent-encoded, and the server saw an unknown route.
        try Self.decode(HealthDayResponse.self, from: try await api.get("\(base)/day", query: ["date": date]).object())
    }

    /// Link or unlink a wearable as a data source. Its history is kept either way.
    func setLinked(_ device: String, _ linked: Bool) async throws {
        _ = try await api.post("\(base)/devices/\(device)", json: ["linked": linked])
    }

    /// Tell the server which wearables exist, so an eligible one gets its
    /// integration without anybody opening a screen first.
    static func register(_ devices: [[String: Any]], api: JarvisAPI = .shared) async throws -> [String] {
        let response = try await api.post("/api/health/devices", json: ["devices": devices])
        return (try response.object()["spaces"] as? [String]) ?? []
    }

    func scores(date: String) async throws -> HealthScores? {
        let response = try await api.get("\(base)/day/\(date)")
        guard let raw = try response.object()["scores"], !(raw is NSNull) else { return nil }
        return try Self.decode(HealthScores.self, from: raw)
    }

    func settings() async throws -> HealthSettings {
        let response = try await api.get("\(base)/settings")
        return try Self.decode(HealthSettings.self, from: try response.object()["settings"] ?? [:])
    }

    /// Write settings. `updates` is a partial: the server deep-merges, so one
    /// rule's threshold can change without restating the others.
    @discardableResult
    func updateSettings(_ updates: [String: Any]) async throws -> HealthSettings {
        var body = updates
        body["source"] = Self.settingsSource
        let response = try await api.post("\(base)/settings", json: body)
        return try Self.decode(HealthSettings.self, from: try response.object()["settings"] ?? [:])
    }

    /// Hand the server a day the phone synced from the ring.
    func pushDay(_ day: [String: Any]) async throws {
        _ = try await api.post("\(base)/day", json: ["day": day])
    }

    /// Run the analysis now. Long timeout: it reaches the ring through the phone.
    @discardableResult
    func runNow() async throws -> [String: Any] {
        let response = try await api.post("\(base)/run", json: ["trigger": "phone"], timeout: 180)
        return (try response.object()["run"] as? [String: Any]) ?? [:]
    }

    static func decodeForTests<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try decoder.decode(type, from: data)
    }
}
