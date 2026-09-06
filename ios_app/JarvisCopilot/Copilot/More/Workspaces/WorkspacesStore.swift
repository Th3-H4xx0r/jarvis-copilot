import Foundation
import Observation

/// Page state for the Workspaces screen: add/rename/remove, drag-to-reorder
/// (applied optimistically, then reconciled with the server), and the debounced
/// path-suggestion lookup for the "Add" sheet.
@Observable
@MainActor
final class WorkspacesStore {
    private let api: WorkspacesAPI
    private let task = TaskHandle()
    private let suggestTask = TaskHandle()
    private let suggestDebounce: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    /// Monotonic id so a slow suggestion response can't replace a newer one.
    private var suggestRequestID = 0

    private(set) var workspaces: [Workspace] = []
    private(set) var last = ""
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    var toast: String?

    private(set) var suggestions: [String] = []

    init(api: WorkspacesAPI = WorkspacesAPI(),
         suggestDebounce: TimeInterval = 0.2,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.suggestDebounce = suggestDebounce
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit {
        task.cancel()
        suggestTask.cancel()
    }

    func isLastUsed(_ workspace: Workspace) -> Bool {
        !last.isEmpty && workspace.path == last
    }

    var isEmpty: Bool { !isLoading && workspaces.isEmpty }

    // MARK: Loading

    func load() {
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        // Only show the full-screen spinner on a cold load; a refresh keeps the
        // list visible.
        if workspaces.isEmpty { isLoading = true }
        do {
            let data = try await api.list()
            workspaces = data.workspaces
            last = data.last
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    // MARK: Mutations

    @discardableResult
    func add(path: String) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "Enter a folder path"
            return false
        }
        do {
            try await api.add(trimmed)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    @discardableResult
    func rename(_ workspace: Workspace, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "Enter a name"
            return false
        }
        do {
            try await api.rename(workspace.path, name: trimmed)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    @discardableResult
    func remove(_ workspace: Workspace) async -> Bool {
        do {
            try await api.remove(workspace.path)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    /// Reorder from a SwiftUI `onMove` (source offsets + destination). The new
    /// order is applied immediately, persisted, then reconciled with the
    /// server's authoritative order and "last used" flag.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var next = workspaces
        next.move(fromOffsets: source, toOffset: destination)
        workspaces = next
        do {
            try await api.reorder(next.map(\.path))
        } catch {
            toast = apiErrorMessage(error)
        }
        await refresh()
    }

    // MARK: Path suggestions

    /// Debounced lookup for the Add sheet. A blank prefix clears the list
    /// without a request.
    func suggest(prefix: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestTask.cancel()
            suggestions = []
            return
        }
        suggestTask.replace(Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper(self.suggestDebounce)
            if Task.isCancelled { return }
            await self.fetchSuggestions(trimmed)
        })
    }

    /// Await the in-flight suggestion lookup (tests).
    func waitForSuggestions() async { await suggestTask.wait() }

    func clearSuggestions() {
        suggestTask.cancel()
        suggestions = []
    }

    private func fetchSuggestions(_ prefix: String) async {
        suggestRequestID += 1
        let id = suggestRequestID
        var hits: [String] = []
        do {
            hits = try await api.suggest(prefix)
        } catch {
            // Path completion is a convenience — the user can still type the
            // whole path — so it degrades to "no suggestions", but silently
            // empty completions are indistinguishable from "no matches".
            JcLog.dropped(JcLog.more, "workspace path suggest", error)
        }
        guard id == suggestRequestID else { return }
        suggestions = hits
    }
}
