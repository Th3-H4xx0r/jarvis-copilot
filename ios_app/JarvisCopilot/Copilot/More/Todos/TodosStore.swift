import Foundation
import Observation

/// Page state for the Todos screen: load the active session's list, sort active
/// work to the top, and expose the "3 / 7 done" counter.
@Observable
@MainActor
final class TodosStore {
    private let api: TodosAPI
    private let task = TaskHandle()

    /// Sorted for display (in-progress, pending, completed, cancelled). The sort
    /// is stable within each group, matching the Flutter list.
    private(set) var todos: [TodoItem] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    init(api: TodosAPI = TodosAPI()) { self.api = api }

    deinit { task.cancel() }

    var doneCount: Int { todos.filter(\.isFinished).count }
    var totalCount: Int { todos.count }
    /// "2 / 5 done" — the section-header trailing label.
    var progressLabel: String { "\(doneCount) / \(totalCount) done" }
    var isEmpty: Bool { hasLoaded && todos.isEmpty }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await self.api.currentSession()
                if Task.isCancelled { return }
                self.apply(items)
            } catch {
                if Task.isCancelled { return }
                self.fail(error)
            }
        })
    }

    /// Pull-to-refresh: awaits the fetch so the spinner tracks the request.
    func refresh() async {
        do {
            let items = try await api.currentSession()
            apply(items)
        } catch {
            fail(error)
        }
    }

    private func apply(_ items: [TodoItem]) {
        todos = TodosStore.sorted(items)
        isLoading = false
        hasLoaded = true
        errorMessage = nil
    }

    private func fail(_ error: Error) {
        isLoading = false
        hasLoaded = true
        errorMessage = apiErrorMessage(error)
    }

    /// Stable sort by status rank so equal-rank rows keep the agent's order.
    /// `nonisolated`: a pure function on values, useful (and testable) off-main.
    nonisolated static func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.enumerated()
            .sorted { l, r in
                l.element.rank == r.element.rank ? l.offset < r.offset : l.element.rank < r.element.rank
            }
            .map(\.element)
    }
}
