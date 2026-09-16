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

    func records(collection: String) async throws -> [IntegrationRecord] {
        guard let id = detailID else { return [] }
        return try await api.records(id, collection: collection)
    }

    func document(key: String) async throws -> String {
        guard let id = detailID else { return "" }
        return try await api.document(id, key: key)
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
        let next = integration.isPaused ? "active" : "paused"
        do {
            try await api.setStatus(integration.id, status: next)
            toast = next == "paused" ? "\(integration.name) paused" : "\(integration.name) resumed"
        } catch {
            toast = apiErrorMessage(error)
        }
        await refresh()
        await reloadDetail()
    }

    /// Removes it and everything inside: its schedules stop, its data is gone.
    func delete(_ integration: Integration) async {
        do {
            try await api.delete(integration.id)
            toast = "\(integration.name) deleted"
            if detailID == integration.id {
                detailID = nil
                detail = nil
            }
        } catch {
            toast = apiErrorMessage(error)
        }
        await refresh()
    }
}
