import Foundation
import Observation

/// The iMessage fact cards on the Chat home: facts Jarvis wants to save from new
/// conversations, each waiting for Store / Skip.
///
/// Never polls (battery): the page loads it on appear, when the app comes back to
/// the foreground, and when a facts push lands or a lock-screen answer goes
/// through (`IMessageFactsPush.changed`).
@Observable
@MainActor
final class IMessageFactsStore {
    private let api: IMessageMemoryAPI
    private let loadTask = TaskHandle()

    private(set) var facts: [IMessageFact] = []
    /// Cards answered but not yet confirmed — a load that lands meanwhile must
    /// not bring them back.
    private var deciding: Set<String> = []
    var toast: String?

    init(api: IMessageMemoryAPI = IMessageMemoryAPI()) {
        self.api = api
    }

    deinit { loadTask.cancel() }

    func load() {
        loadTask.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            let next = try await api.facts()
            facts = next.filter { !deciding.contains($0.id) }
        } catch {
            // Quietly: the home screen shows no cards rather than an error, and an
            // older server (no /facts route yet) answers 404 here.
            if !wasCancelled(error) { JcLog.dropped(JcLog.services, "imessage facts load", error) }
        }
    }

    /// Store or skip one card. It leaves at once; a failure puts it back and says why.
    func decide(_ fact: IMessageFact, store: Bool) async {
        guard let index = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        deciding.insert(fact.id)
        facts.remove(at: index)
        defer { deciding.remove(fact.id) }
        do {
            try await api.decide(ids: [fact.id], store: store)
        } catch {
            if !facts.contains(where: { $0.id == fact.id }) {
                facts.insert(fact, at: min(index, facts.count))
            }
            let what = store ? "Couldn't save that fact" : "Couldn't skip that fact"
            toast = "\(what): \(apiErrorMessage(error))"
        }
    }
}
