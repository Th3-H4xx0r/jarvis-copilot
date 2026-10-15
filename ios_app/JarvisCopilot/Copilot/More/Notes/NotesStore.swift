import Foundation
import Observation

/// More → Notes: the call notes from the Mac and each one's detail.
///
/// Push-driven: while the list or a note is on screen the store wants the
/// `notes` bridge topic, which the server publishes on every change (a note
/// uploaded, its summary written, a to-do ticked, a note deleted). It fetches
/// when a screen appears and after a reconnect, never on a timer.
@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [AgentNote] = []
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var details: [String: AgentNote] = [:]
    private(set) var detailErrors: [String: String] = [:]
    /// The transient banner (`moreToast`).
    var toast: String?

    @ObservationIgnored private let api: NotesAPI
    @ObservationIgnored private let topics: BridgeTopics
    @ObservationIgnored private var watchers: Set<String> = []

    init(api: NotesAPI = NotesAPI(), topics: BridgeTopics? = nil) {
        let topics = topics ?? .shared
        self.api = api
        self.topics = topics
        topics.on("notes") { [weak self] data in self?.pushed(data) }
        topics.onResync { [weak self] in
            guard let self, !self.watchers.isEmpty else { return }
            Task { await self.refresh() }
        }
    }

    func setVisible(_ on: Bool, owner: String) {
        let was = !watchers.isEmpty
        if on {
            guard watchers.insert(owner).inserted else { return }
            topics.want("notes", owner: owner, every: 0)
            if !was { Task { await refresh() } }
        } else {
            guard watchers.remove(owner) != nil else { return }
            topics.drop("notes", owner: owner)
        }
    }

    func refresh() async {
        do {
            notes = try await api.list()
            loadError = nil
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
        }
        loaded = true
    }

    func load(_ id: String) async {
        do {
            let note = try await api.note(id)
            details[id] = note
            detailErrors[id] = nil
            replaceRow(note)
        } catch {
            detailErrors[id] = apiErrorMessage(error)
        }
    }

    func toggleTodo(_ id: String, index: Int) async {
        guard let note = details[id] else { return }
        do {
            let updated = try await api.setTodos(id, note.todosJSON(toggling: index))
            details[id] = updated
            replaceRow(updated)
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func summarize(_ id: String) async {
        do {
            let updated = try await api.summarize(id)
            details[id] = updated
            replaceRow(updated)
            toast = "Jarvis is writing the summary"
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func delete(_ id: String) async -> Bool {
        do {
            try await api.delete(id)
            remove(id)
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    func markdown(_ id: String) async -> (text: String, filename: String)? {
        do {
            return try await api.markdown(id)
        } catch {
            toast = apiErrorMessage(error)
            return nil
        }
    }

    // MARK: pushes

    private func pushed(_ data: [String: Any]) {
        guard let id = CodingJSON.str(data["id"]) else {
            if !watchers.isEmpty { Task { await refresh() } }
            return
        }
        if CodingJSON.bool(data["deleted"]) {
            remove(id)
            return
        }
        guard !watchers.isEmpty else { return }
        Task {
            await refresh()
            if details[id] != nil { await load(id) }
        }
    }

    private func remove(_ id: String) {
        notes.removeAll { $0.id == id }
        details[id] = nil
    }

    private func replaceRow(_ note: AgentNote) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
    }
}
