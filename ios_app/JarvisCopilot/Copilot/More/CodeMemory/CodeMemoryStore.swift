import Foundation
import Observation

/// Overview screen: stats + project list + the client-side project filter.
@Observable
@MainActor
final class CodeMemoryStore {
    private let api: CodeMemoryAPI
    private let task = TaskHandle()

    private(set) var overview = CodeMemoryOverview()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var filter = ""

    init(api: CodeMemoryAPI = CodeMemoryAPI()) { self.api = api }

    deinit { task.cancel() }

    /// Projects passing the search box, in server order.
    var visibleProjects: [CodeMemoryProject] {
        overview.projects.filter { $0.matches(filter) }
    }

    /// No projects at all (vs. "filter matched nothing").
    var isEmpty: Bool { hasLoaded && overview.projects.isEmpty }
    var filterMatchedNothing: Bool {
        !overview.projects.isEmpty && visibleProjects.isEmpty
    }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    /// Stats and projects are independent GETs; a stats failure must not cost us
    /// the project list, so the totals fall back to summing the projects.
    func refresh() async {
        var stats = CodeMemoryStats()
        do {
            stats = try await api.stats()
        } catch {
            // The header totals fall back to summing the projects; log so a
            // header that disagrees with the list has an explanation.
            JcLog.dropped(JcLog.more, "code-memory stats", error)
        }
        do {
            let projects = try await api.projects()
            overview = CodeMemoryOverview(stats: stats, projects: projects)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    func clearFilter() { filter = "" }

    /// A child store for one project's Knowledge / Handoffs tab.
    func entriesStore(slug: String, kind: CodeMemoryKind) -> CodeMemoryEntriesStore {
        CodeMemoryEntriesStore(api: api, slug: slug, kind: kind)
    }
}

/// One project + one kind: list, search (with body hydration), edit, delete.
@Observable
@MainActor
final class CodeMemoryEntriesStore {
    private let api: CodeMemoryAPI
    let slug: String
    let kind: CodeMemoryKind
    private let task = TaskHandle()

    private(set) var entries: [CodeMemoryEntry] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var query = ""
    /// One-shot message for the toast (delete confirmed, edit failed, …).
    var toast: String?
    /// Bumped after every successful mutation so the parent can re-read counts.
    private(set) var mutationCount = 0

    init(api: CodeMemoryAPI = CodeMemoryAPI(), slug: String, kind: CodeMemoryKind) {
        self.api = api
        self.slug = slug
        self.kind = kind
    }

    deinit { task.cancel() }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            entries = try await fetch()
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    /// Empty query → the plain list. Otherwise search (compact rows) and hydrate
    /// the bodies by id, falling back to the compact rows if hydration fails.
    private func fetch() async throws -> [CodeMemoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return try await api.entries(slug, kind: kind) }

        let hits = try await api.search(slug, query: q, kind: kind)
        if hits.isEmpty { return [] }
        let ids = hits.map(\.id).filter { !$0.isEmpty }
        if let full = try? await api.byIDs(ids), !full.isEmpty { return full }
        return hits
    }

    /// Edit one entry. Returns false (and sets `toast`) when it didn't stick.
    @discardableResult
    func update(_ entry: CodeMemoryEntry, content: String) async -> Bool {
        guard !entry.id.isEmpty else {
            toast = "This entry has no id; cannot edit."
            return false
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast = "Content cannot be empty."
            return false
        }
        do {
            try await api.update(id: entry.id, content: content)
            await refresh()
            mutationCount += 1
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    /// Delete one entry, preferring the precise id form.
    @discardableResult
    func delete(_ entry: CodeMemoryEntry) async -> Bool {
        do {
            if !entry.id.isEmpty {
                try await api.deleteEntry(id: entry.id)
            } else {
                try await api.deleteEntry(slug: entry.slug.isEmpty ? slug : entry.slug,
                                          kind: entry.kind.isEmpty ? kind.rawValue : entry.kind,
                                          ts: entry.ts)
            }
            await refresh()
            mutationCount += 1
            toast = "Entry deleted."
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }
}
