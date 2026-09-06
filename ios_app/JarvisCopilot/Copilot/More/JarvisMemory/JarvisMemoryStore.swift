import Foundation
import Observation

/// Page state for the Long-term memory screen.
///
/// The header (stats + namespaces + reflections) and the search results are two
/// independent lifecycles, exactly as in Flutter: typing must not reload the
/// header, and a stale search response must not overwrite a newer one.
@Observable
@MainActor
final class JarvisMemoryStore {
    private let api: JarvisMemoryAPI
    /// Debounce for the search box. Injected so tests don't sleep.
    private let searchDebounce: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private let headerTask = TaskHandle()
    private let searchTask = TaskHandle()
    /// Monotonic request id — a late response with a stale id is discarded.
    private var searchRequestID = 0

    private(set) var data = JarvisMemoryData()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    var query = ""
    private(set) var lastQuery = ""
    private(set) var isSearching = false
    private(set) var results: [MemoryEntry] = []
    /// One-shot user-facing message (delete failed, reflection started, …).
    var toast: String?

    init(api: JarvisMemoryAPI = JarvisMemoryAPI(),
         searchDebounce: TimeInterval = 0.22,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.searchDebounce = searchDebounce
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit {
        headerTask.cancel()
        searchTask.cancel()
    }

    var available: Bool { data.available }
    var unavailableMessage: String? { data.unavailableMessage }
    var reflections: [MemoryReflection] { data.reflections }
    var namespaces: [MemoryNamespace] { data.namespaces }

    // MARK: Loading

    /// Open the screen: load the header and populate the recent-entries list
    /// (the backend returns recent entries for an empty query, mirroring the
    /// web panel, which searches on open).
    func onAppear() {
        reload()
        runSearch("")
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        headerTask.replace(Task { [weak self] in
            await self?.loadHeader()
        })
    }

    /// Pull-to-refresh: header plus a re-run of the current search.
    func refresh() async {
        await loadHeader()
        await performSearch(query)
    }

    private func loadHeader() async {
        do {
            let stats = try await api.stats()
            let status = try await api.status()
            // Reflections fail-soft independently; never let them sink the page.
            var reflections: [MemoryReflection] = []
            do {
                reflections = try await api.reflections()
            } catch {
                JcLog.dropped(JcLog.more, "jarvis-memory reflections", error)
            }
            data = JarvisMemoryData(stats: stats, status: status, reflections: reflections)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    // MARK: Search

    /// Called on every keystroke; debounced.
    func queryChanged(_ value: String) {
        query = value
        searchTask.replace(Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper(self.searchDebounce)
            if Task.isCancelled { return }
            await self.performSearch(value)
        })
    }

    /// Search immediately (submit button, open, refresh).
    func runSearch(_ value: String) {
        searchTask.replace(Task { [weak self] in
            await self?.performSearch(value)
        })
    }

    /// Await the in-flight debounce/search (tests).
    func waitForSearch() async { await searchTask.wait() }

    private func performSearch(_ value: String) async {
        searchRequestID += 1
        let id = searchRequestID
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        lastQuery = trimmed
        do {
            let hits = try await api.search(trimmed)
            guard id == searchRequestID else { return }
            results = hits
        } catch {
            guard id == searchRequestID else { return }
            results = []
            toast = apiErrorMessage(error)
        }
        if id == searchRequestID { isSearching = false }
    }

    // MARK: Mutations

    /// Forget one entry: drop it from the results optimistically, then reload
    /// the header so the count updates.
    func deleteEntry(_ id: String) async {
        guard !id.isEmpty else { return }
        do {
            try await api.deleteEntry(id)
            results.removeAll { $0.id == id }
            await loadHeader()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func dismissReflection(_ id: String) async {
        guard !id.isEmpty else { return }
        do {
            try await api.dismissReflection(id)
            await loadHeader()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func runReflections() async {
        do {
            try await api.runReflections()
            toast = "Reflection started"
            await loadHeader()
        } catch {
            toast = apiErrorMessage(error)
        }
    }
}
