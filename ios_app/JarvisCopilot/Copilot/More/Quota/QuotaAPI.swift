import Foundation

/// REST wrapper for provider quota/usage (`/api/provider/quota/all`).
///
/// One call returns every configured quota-capable provider (Claude Code,
/// Codex, plus Anthropic / OpenRouter when configured), each with its limit
/// windows carrying a `used_percent` for the progress bars.
struct QuotaAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `refresh` forces the server to re-poll upstream rather than serve cache.
    func all(refresh: Bool = false) async throws -> [QuotaProvider] {
        let query = refresh ? ["refresh": "1"] : [:]
        let body = try await api.get("/api/provider/quota/all", query: query).object()
        return MoreJSON.mapList(MoreJSON.envelopeList(body, "providers")).map(QuotaProvider.init(json:))
    }
}
