import Foundation
import Observation

/// The Memories tab of a chat's preview sheet: what Jarvis remembers from one chat.
///
/// Loads once when the tab is first shown and again on pull-to-refresh — never on
/// a timer (battery).
@Observable
@MainActor
final class IMessageChatMemoriesStore {
    enum Kind { case fact, conversation }

    let guid: String
    private let api: IMessageMemoryAPI

    private(set) var memories: IMessageChatMemories?
    private(set) var errorMessage: String?
    var toast: String?

    /// Rows removed but not yet confirmed — a load that lands meanwhile must not
    /// bring them back. Kept apart: a stored card may come back as a fact.
    private var deleting: Set<String> = []
    private var deciding: Set<String> = []

    init(guid: String, api: IMessageMemoryAPI = IMessageMemoryAPI()) {
        self.guid = guid
        self.api = api
    }

    /// The first load (and Retry): a spinner, then the lists or an error.
    func load() async {
        errorMessage = nil
        await fetch(showingError: memories == nil)
    }

    /// Pull-to-refresh: the lists stay while it runs; a failure is a toast.
    func refresh() async {
        await fetch(showingError: memories == nil)
    }

    private func fetch(showingError: Bool) async {
        do {
            var next = try await api.memories(guid)
            next.facts.removeAll { deleting.contains($0.id) }
            next.conversations.removeAll { deleting.contains($0.id) }
            next.waiting.removeAll { deciding.contains($0.id) }
            memories = next
            errorMessage = nil
        } catch {
            guard !wasCancelled(error) else { return }
            if showingError {
                errorMessage = apiErrorMessage(error)
            } else {
                toast = apiErrorMessage(error)
            }
        }
    }

    // MARK: Delete

    /// Deletes a fact or conversation. It leaves at once; a failure puts it back and says why.
    func delete(_ entry: IMessageMemoryEntry, _ kind: Kind) async {
        guard let index = list(kind).firstIndex(where: { $0.id == entry.id }) else { return }
        deleting.insert(entry.id)
        mutate(kind) { $0.remove(at: index) }
        do {
            // `deleted: false` = already gone, which is what he asked for.
            try await api.deleteMemory(entry.id)
        } catch {
            deleting.remove(entry.id)
            mutate(kind) { rows in
                if !rows.contains(where: { $0.id == entry.id }) { rows.insert(entry, at: min(index, rows.count)) }
            }
            toast = "Couldn't delete that: \(apiErrorMessage(error))"
        }
    }

    private func list(_ kind: Kind) -> [IMessageMemoryEntry] {
        switch kind {
        case .fact: return memories?.facts ?? []
        case .conversation: return memories?.conversations ?? []
        }
    }

    private func mutate(_ kind: Kind, _ change: (inout [IMessageMemoryEntry]) -> Void) {
        switch kind {
        case .fact: if memories != nil { change(&memories!.facts) }
        case .conversation: if memories != nil { change(&memories!.conversations) }
        }
    }

    // MARK: Waiting cards

    /// Store or skip a waiting card — the Chat-home cards' call. The row leaves at
    /// once; Store reloads so the saved fact shows under Facts.
    func decide(_ fact: IMessageFact, store: Bool) async {
        guard let index = memories?.waiting.firstIndex(where: { $0.id == fact.id }) else { return }
        deciding.insert(fact.id)
        memories?.waiting.remove(at: index)
        do {
            try await api.decide(ids: [fact.id], store: store)
        } catch {
            deciding.remove(fact.id)
            if let waiting = memories?.waiting, !waiting.contains(where: { $0.id == fact.id }) {
                memories?.waiting.insert(fact, at: min(index, waiting.count))
            }
            let what = store ? "Couldn't save that fact" : "Couldn't skip that fact"
            toast = "\(what): \(apiErrorMessage(error))"
            return
        }
        // The Chat home's cards drop it too.
        NotificationCenter.default.post(name: IMessageFactsPush.changed, object: nil)
        if store { await fetch(showingError: false) }
    }
}
