import Foundation
import Observation

/// Page state for the Long-term memory screen.
///
/// The header (stats + namespaces + reflections) and the search results are two
/// independent lifecycles: typing must not reload the header, and a stale search
/// response must not overwrite a newer one.
@Observable
@MainActor
final class JarvisMemoryStore {
    private static let searchDebounce: TimeInterval = 0.22

    private let api: JarvisMemoryAPI
    /// Injected so tests don't wait out the search debounce.
    private let sleeper: Sleeper

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

    init(api: JarvisMemoryAPI = JarvisMemoryAPI(), sleeper: @escaping Sleeper = wallClockSleeper) {
        self.api = api
        self.sleeper = sleeper
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
            try? await self.sleeper(Self.searchDebounce)
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

/// The memory map half of the Long-term memory screen: which model maps
/// memories, and the Cleanup card.
///
/// Its own lifecycle, apart from the header and search: the cleanup status is
/// polled every 3 s while a run is going and the page is on screen, and a server
/// without these endpoints just leaves both sections hidden.
@Observable
@MainActor
final class MemoryMapStore {
    static let pollInterval: TimeInterval = 3

    private let api: JarvisMemoryAPI
    private let sleeper: Sleeper
    private let pollTask = TaskHandle()
    private var visible = false

    /// nil until loaded (or when the server doesn't have the setting).
    private(set) var settings: MemoryMapSettings?
    private(set) var cleanup: MemoryCleanupStatus?
    private(set) var startingCleanup = false
    /// Rows restored this visit, so their button reads "Restored".
    private(set) var restored: Set<String> = []
    var toast: String?

    init(api: JarvisMemoryAPI = JarvisMemoryAPI(), sleeper: @escaping Sleeper = wallClockSleeper) {
        self.api = api
        self.sleeper = sleeper
    }

    deinit { pollTask.cancel() }

    func appeared() {
        visible = true
        Task { await load() }
    }

    func disappeared() {
        visible = false
        pollTask.cancel()
    }

    func load() async {
        do {
            settings = try await api.mapSettings()
        } catch {
            JcLog.dropped(JcLog.more, "memory map settings", error)
        }
        await refreshCleanup()
    }

    /// nil = Same as Default.
    func setAgent(_ choice: AgentChoice?) async {
        let previous = settings
        settings = MemoryMapSettings(agent: choice, label: settings?.label ?? "")
        do {
            settings = try await api.setMapAgent(choice)
        } catch {
            settings = previous
            toast = apiErrorMessage(error)
        }
    }

    func runCleanup() async {
        guard !startingCleanup else { return }
        startingCleanup = true
        defer { startingCleanup = false }
        do {
            try await api.startCleanup()
        } catch {
            toast = apiErrorMessage(error)
            return
        }
        await refreshCleanup()
    }

    func restore(_ id: String) async {
        guard !id.isEmpty, !restored.contains(id) else { return }
        do {
            try await api.restore([id])
            restored.insert(id)
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    private func refreshCleanup() async {
        do {
            cleanup = try await api.cleanupStatus()
        } catch {
            JcLog.dropped(JcLog.more, "memory cleanup status", error)
        }
        if cleanup?.running == true { startPolling() } else { pollTask.cancel() }
    }

    private func startPolling() {
        guard visible else { return }
        pollTask.poll(self, every: Self.pollInterval, sleeper: sleeper) { store in
            await store.refreshCleanup()
        }
    }
}
