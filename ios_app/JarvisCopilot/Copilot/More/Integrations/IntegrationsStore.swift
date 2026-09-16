import Foundation
import Observation

/// Page state for the Integrations screen: the list, and the one integration
/// currently open. No polling — an integration changes when the user changes it,
/// or when a schedule inside it runs, and the schedule screen does its own.
@Observable
@MainActor
final class IntegrationsStore {
    private let api: IntegrationsAPI
    private let loadTask = TaskHandle()

    private(set) var integrations: [Integration] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var toast: String?

    /// The integration whose screen is open, and what it holds.
    private(set) var detail: IntegrationDetail?
    private(set) var detailID: String?
    private(set) var detailError: String?

    init(api: IntegrationsAPI = IntegrationsAPI()) { self.api = api }

    deinit { loadTask.cancel() }

    var isEmpty: Bool { hasLoaded && integrations.isEmpty }

    // MARK: Lifecycle

    func load() {
        isLoading = true
        errorMessage = nil
        loadTask.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            integrations = try await api.list()
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    func onDisappear() { loadTask.cancel() }

    // MARK: One integration

    func open(_ id: String) async {
        detailID = id
        detail = nil
        detailError = nil
        await reloadDetail()
    }

    func reloadDetail() async {
        guard let id = detailID else { return }
        do {
            let loaded = try await api.detail(id)
            // The screen may have moved on while this was in flight.
            guard detailID == id else { return }
            detail = loaded
            detailError = nil
        } catch {
            guard detailID == id else { return }
            detailError = apiErrorMessage(error)
        }
    }

    func records(in id: String, collection: String) async throws -> [IntegrationRecord] {
        try await api.records(id, collection: collection)
    }

    func document(in id: String, key: String) async throws -> String {
        try await api.document(id, key: key)
    }

    /// The freshest copy of one integration: the list is refetched far more often
    /// than a detail screen is pushed, so the pushed value goes stale immediately.
    func current(_ id: String) -> Integration? {
        detail?.integration.id == id ? detail?.integration
            : integrations.first { $0.id == id }
    }

    // MARK: Mutations

    func create(name: String) async -> Integration? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let made = try await api.create(name: trimmed)
            toast = "\(made.name) created"
            await refresh()
            return made
        } catch {
            toast = apiErrorMessage(error)
            return nil
        }
    }

    func togglePause(_ integration: Integration) async {
        // From the freshest copy, not the one the screen was pushed with — that one
        // never changes, so Pause worked once and Resume was unreachable.
        let live = current(integration.id) ?? integration
        let next = live.isPaused ? "active" : "paused"
        do {
            try await api.setStatus(live.id, status: next)
            toast = next == "paused" ? "\(live.name) paused" : "\(live.name) resumed"
        } catch {
            toast = apiErrorMessage(error)
        }
        await refresh()
        await reloadDetail()
    }

    /// Removes it and everything inside: its schedules stop, its data is gone.
    /// Returns whether it is gone, so its screen knows to close itself.
    @discardableResult
    func delete(_ integration: Integration) async -> Bool {
        do {
            try await api.delete(integration.id)
            toast = "\(integration.name) deleted"
        } catch {
            toast = apiErrorMessage(error)
            await refresh()
            return false
        }
        if detailID == integration.id {
            detailID = nil
            detail = nil
        }
        await refresh()
        return true
    }
}
