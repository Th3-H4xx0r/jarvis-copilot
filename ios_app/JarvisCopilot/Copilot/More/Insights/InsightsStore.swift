import Foundation
import Observation

/// Page state for the Insights screen.
///
/// The four sub-fetches run concurrently and each degrades on its own: only the
/// overview can fail the page, because that's the data the screen is *about*.
@Observable
@MainActor
final class InsightsStore {
    private let api: InsightsAPI
    private let task = TaskHandle()

    private(set) var bundle = InsightsBundle()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    /// The selected window; changing it reloads.
    private(set) var days = 30

    init(api: InsightsAPI = InsightsAPI()) { self.api = api }

    deinit { task.cancel() }

    var overview: InsightsOverview { bundle.overview }
    var health: SystemHealth { bundle.health }
    var wiki: WikiStatus { bundle.wiki }
    var messages: [MessageUsage] { bundle.messages }
    var showsMessages: Bool { bundle.hasSession }
    var isEmpty: Bool { hasLoaded && bundle.overview.isEmpty }

    func setDays(_ value: Int) {
        guard value != days else { return }
        days = value
        load()
    }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        let window = days
        async let overview = api.overview(days: window)
        async let health = api.systemHealth()
        async let wiki = api.wikiStatus()
        async let session = api.activeSessionID()

        let (loadedHealth, loadedWiki, sessionID) = await (health, wiki, session)
        let loadedMessages = await api.messages(sessionID: sessionID)

        do {
            let loadedOverview = try await overview
            bundle = InsightsBundle(overview: loadedOverview,
                                    health: loadedHealth,
                                    wiki: loadedWiki,
                                    hasSession: sessionID?.isEmpty == false,
                                    sessionID: sessionID,
                                    messages: loadedMessages)
            errorMessage = nil
        } catch {
            // Keep whatever the side sections returned; only the overview failed.
            bundle = InsightsBundle(overview: InsightsOverview(),
                                    health: loadedHealth,
                                    wiki: loadedWiki,
                                    hasSession: sessionID?.isEmpty == false,
                                    sessionID: sessionID,
                                    messages: loadedMessages)
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }
}
