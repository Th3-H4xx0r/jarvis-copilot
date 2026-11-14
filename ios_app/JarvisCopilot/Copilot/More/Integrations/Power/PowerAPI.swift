import Foundation

/// `/api/power`: the Power integrations, their switches and settings.
struct PowerAPI {
    static let prefix = "/api/power"
    var api: JarvisAPI = .shared

    func list() async throws -> [String: Any] {
        try await api.get(Self.prefix, timeout: 30).object()
    }

    /// `{enabled}` and/or `{settings}`; returns the server's reply (`ok`, `row` or `pending`).
    func change(_ id: String, body: [String: Any]) async throws -> [String: Any] {
        var payload = body
        payload["client"] = "ios"
        return try await api.post(Self.prefix + "/" + Self.escape(id), json: payload, timeout: 60).object()
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}
