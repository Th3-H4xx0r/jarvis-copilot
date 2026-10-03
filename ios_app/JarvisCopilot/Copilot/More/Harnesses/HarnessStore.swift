import Foundation
import Observation

/// The harnesses the server knows (built-ins + yours) and the Voice/Chat
/// defaults, shared by the harness chip, the Harnesses page and the turn
/// senders (chat/start and voice begin_turn carry `harness_id`).
@Observable
@MainActor
final class HarnessStore {
    static let shared = HarnessStore()

    static let defaultAssignments = ["voice": "fast-claude", "chat": "single"]

    private let api: HarnessAPI
    var harnesses: [AgentHarness] = []
    var assignments: [String: String] = HarnessStore.defaultAssignments
    private(set) var isLoading = false
    var errorMessage: String?

    init(api: HarnessAPI = HarnessAPI()) { self.api = api }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await api.snapshot()
            harnesses = snap.harnesses
            assignments = HarnessStore.defaultAssignments.merging(snap.assignments) { _, new in new }
            persistVoiceChoice()
            errorMessage = nil
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }

    func harness(_ id: String) -> AgentHarness? { harnesses.first { $0.id == id } }

    /// The harness a turn on this surface runs: the chat's own, else the default.
    func current(for surface: VoiceSurface, sessionHarnessID: String?) -> String {
        if surface == .chat, let id = sessionHarnessID, !id.isEmpty { return id }
        return assignments[surface.rawValue] ?? HarnessStore.defaultAssignments[surface.rawValue] ?? "single"
    }

    func title(for id: String) -> String { harness(id)?.title ?? id }

    /// Chat: the chat's own harness. Voice: the Voice default.
    func select(_ id: String, surface: VoiceSurface, sessionID: String?) async {
        do {
            if surface == .chat, let sessionID {
                try await api.setSessionHarness(sessionID: sessionID, id: id)
            } else {
                assignments = HarnessStore.defaultAssignments
                    .merging(try await api.assign(surface: surface.rawValue, id: id)) { _, new in new }
                persistVoiceChoice()
            }
            errorMessage = nil
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }

    /// The voice transport (shared with the Mac client) reads the Voice
    /// harness from UserDefaults rather than this store.
    private func persistVoiceChoice() {
        UserDefaults.standard.set(assignments["voice"], forKey: voiceHarnessDefaultsKey)
    }

    func assign(_ id: String, to surface: VoiceSurface) async {
        await select(id, surface: surface, sessionID: nil)
    }

    /// Saves and refreshes; returns the server's problems when it rejects the design.
    func save(_ harness: AgentHarness) async -> [HarnessProblem] {
        do {
            switch try await api.save(harness) {
            case .success:
                await refresh()
                return []
            case .failure(let rejection):
                return rejection.problems
            }
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
            return [HarnessProblem(node: nil, edge: nil, message: error.localizedDescription)]
        }
    }

    func delete(_ id: String) async {
        do {
            try await api.delete(id: id)
            await refresh()
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }
}
