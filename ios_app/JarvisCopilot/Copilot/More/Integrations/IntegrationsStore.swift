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
            // A cancelled request is this screen being left or reloaded, not a
            // failure — reporting it puts the word "cancelled" where the data goes.
            if !Self.wasCancelled(error) { errorMessage = apiErrorMessage(error) }
        }
        isLoading = false
        hasLoaded = true
    }

    func onDisappear() { loadTask.cancel() }

    /// A request that was cancelled because the screen was left, a refresh
    /// superseded it, or the tab changed. Nothing went wrong, so nothing is said.
    static func wasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

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
            guard detailID == id, !Self.wasCancelled(error) else { return }
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

    func deleteCollection(_ name: String) async {
        guard let id = detailID else { return }
        await mutate("\(name) deleted") { try await self.api.deleteCollection(id, name: name) }
    }

    func deleteDocument(_ key: String) async {
        guard let id = detailID else { return }
        await mutate("\(key) deleted") { try await self.api.deleteDocument(id, key: key) }
    }

    func deleteSkill(_ name: String, mode: SkillDeleteMode) async {
        guard let id = detailID else { return }
        let done = mode == .file ? "\(name) deleted" : "\(name) removed from this integration"
        await mutate(done) { try await self.api.deleteSkill(id, name: name, mode: mode) }
    }

    /// Removes only the parts chosen.
    ///
    /// Two different questions, and the screen needs both: whether it worked (so a
    /// failure can keep the sheet open with the choices intact) and whether the
    /// integration itself went (so the screen knows to close).
    struct DeleteOutcome: Equatable, Sendable {
        var succeeded: Bool
        var spaceRemoved: Bool
    }

    @discardableResult
    func delete(_ integration: Integration, parts: IntegrationDeleteChoice) async -> DeleteOutcome {
        do {
            try await api.deleteParts(integration.id, parts)
            toast = parts.space ? "\(integration.name) deleted" : "Removed"
        } catch {
            toast = apiErrorMessage(error)
            await refresh()
            await reloadDetail()
            return DeleteOutcome(succeeded: false, spaceRemoved: false)
        }
        if parts.space, detailID == integration.id {
            detailID = nil
            detail = nil
        }
        await refresh()
        if !parts.space { await reloadDetail() }
        return DeleteOutcome(succeeded: true, spaceRemoved: parts.space)
    }

    /// Runs a change, says what happened, and reloads what the screen is showing.
    private func mutate(_ done: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            toast = done
        } catch {
            toast = apiErrorMessage(error)
        }
        await reloadDetail()
        await refresh()
    }

}
