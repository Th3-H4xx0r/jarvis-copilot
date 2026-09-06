import Foundation
import Observation

/// State for the Settings "Quota & Usage" card.
///
/// `isRefreshing` is separate from `isLoading` so the manual refresh shows a
/// small spinner in the header while the already-loaded bars stay on screen.
/// A failure with data still in hand keeps the data — a stale bar beats a blank
/// card — and only shows the retry note when there is nothing to show.
@Observable
@MainActor
final class QuotaStore {
    private let api: QuotaAPI
    private let task = TaskHandle()

    private(set) var providers: [QuotaProvider] = []
    private(set) var isLoading = true
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    init(api: QuotaAPI = QuotaAPI()) { self.api = api }

    deinit { task.cancel() }

    /// No quota-capable providers are configured (vs. still loading).
    var isEmpty: Bool { !isLoading && errorMessage == nil && providers.isEmpty }
    /// Show the "Couldn't load usage" + Retry note.
    var showsRetry: Bool { errorMessage != nil && providers.isEmpty }
    var emptyText: String { "No quota-capable providers configured." }

    func load() {
        task.replace(Task { [weak self] in await self?.refresh(initial: true) })
    }

    /// `force` asks the server to re-poll upstream.
    func reload(force: Bool = true) {
        task.replace(Task { [weak self] in await self?.refresh(force: force) })
    }

    func refresh(initial: Bool = false, force: Bool = false) async {
        if !initial { isRefreshing = true }
        do {
            providers = try await api.all(refresh: force)
            errorMessage = nil
        } catch {
            // Matches the Flutter card, which shows a fixed line rather than the
            // raw transport error.
            errorMessage = "Couldn’t load usage"
        }
        isLoading = false
        isRefreshing = false
    }
}
