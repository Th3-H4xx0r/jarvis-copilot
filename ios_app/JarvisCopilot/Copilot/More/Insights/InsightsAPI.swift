import Foundation

/// REST wrapper for the WebUI usage analytics (`/api/insights`) plus the
/// companion observability endpoints the Insights panel renders alongside it:
/// host health (`/api/system/health`), LLM Wiki status (`/api/wiki/status`) and
/// per-message token usage for one session (`/api/insights/messages`).
///
/// `systemHealth` / `wikiStatus` / `messages` never throw: each section must be
/// able to degrade on its own, so a failure yields an empty (or error-shaped)
/// value instead of sinking the page.
struct InsightsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/insights?days=N` (the backend clamps N to 1…365).
    func overview(days: Int = 30) async throws -> InsightsOverview {
        let body = try await api.get("/api/insights", query: ["days": "\(days)"]).object()
        return InsightsOverview(json: body)
    }

    /// A `failed` value on any failure, so the section can render "Unavailable"
    /// rather than disappearing — a host that cannot be reached must not look
    /// the same as one that reports nothing.
    func systemHealth() async -> SystemHealth {
        do {
            let body = try await api.get("/api/system/health").object()
            return SystemHealth(json: body)
        } catch {
            JcLog.dropped(JcLog.more, "system health", error)
            var health = SystemHealth()
            health.failed = true
            return health
        }
    }

    /// An error-shaped value on failure so the section can render "Unavailable".
    func wikiStatus() async -> WikiStatus {
        do {
            return WikiStatus(json: try await api.get("/api/wiki/status").object())
        } catch {
            JcLog.dropped(JcLog.more, "wiki status", error)
            var status = WikiStatus()
            status.status = "error"
            return status
        }
    }

    /// Per-message token usage for ONE session. The backend keys this on
    /// `session_id` (NOT `days`); without an id it returns nothing.
    func messages(sessionID: String?) async -> [MessageUsage] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        do {
            let body = try await api.get("/api/insights/messages",
                                         query: ["session_id": sessionID]).object()
            return Insights.parseRows(MoreJSON.envelopeList(body, "messages"))
                .map(MessageUsage.init(json:))
        } catch {
            JcLog.dropped(JcLog.more, "insights messages", error)
            return []
        }
    }

    /// Resolve the active chat session the way the Todos screen does — the
    /// most-recently-updated session. nil when there are none, so the Messages
    /// section hides.
    func activeSessionID() async -> String? {
        do {
            return try await TodosAPI(api: api).activeSessionID()
        } catch {
            JcLog.dropped(JcLog.more, "insights active session", error)
            return nil
        }
    }
}
