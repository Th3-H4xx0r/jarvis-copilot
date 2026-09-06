import Foundation
import Observation

/// Page state for the "Learning" screen: what the agent has been teaching
/// itself, newest first (the server already orders it that way).
@Observable
@MainActor
final class SelfImprovementStore {
    private let api: SelfImprovementAPI
    private let task = TaskHandle()

    private(set) var events: [SelfImprovementEvent] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    init(api: SelfImprovementAPI = SelfImprovementAPI()) { self.api = api }

    deinit { task.cancel() }

    var isEmpty: Bool { hasLoaded && events.isEmpty }
    var emptyText: String {
        "No self-improvement activity yet.\n"
            + "After a substantial task, skills/memory the agent saves on its own "
            + "will show up here."
    }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            events = try await api.recent()
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }
}
