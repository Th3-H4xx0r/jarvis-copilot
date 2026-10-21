import Foundation
import Observation

/// State for the iMessage memory screen and the pinned card above the integrations.
///
/// Polls only while a backfill is in flight AND the screen is on show: a backfill is
/// the one thing here that changes without him touching it.
@Observable
@MainActor
final class IMessageMemoryStore {
    private let api: IMessageMemoryAPI
    private let sleeper: Sleeper
    private let loadTask = TaskHandle()
    private let pollTask = TaskHandle()

    private(set) var card: IMessageMemoryCard?
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// A backfill being asked for — the Run button spins.
    private(set) var startingBackfill = false
    var toast: String?

    /// Whether the screen is showing; polling stops the moment it isn't.
    private var visible = false

    static let pollInterval: TimeInterval = 5

    init(api: IMessageMemoryAPI = IMessageMemoryAPI(), sleeper: @escaping Sleeper = wallClockSleeper) {
        self.api = api
        self.sleeper = sleeper
    }

    deinit {
        loadTask.cancel()
        pollTask.cancel()
    }

    // MARK: Lifecycle

    func load() {
        loadTask.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            apply(try await api.card())
            errorMessage = nil
        } catch {
            if !wasCancelled(error) { errorMessage = apiErrorMessage(error) }
        }
        hasLoaded = true
    }

    func appeared() {
        visible = true
        load()
    }

    func disappeared() {
        visible = false
        syncPolling()
    }

    var isPolling: Bool { pollTask.isActive }

    private func apply(_ next: IMessageMemoryCard) {
        card = next
        syncPolling()
    }

    private func syncPolling() {
        guard visible, card?.activeJob != nil else {
            pollTask.cancel()
            return
        }
        pollTask.poll(self, every: Self.pollInterval, sleeper: sleeper) { store in
            await store.refresh()
        }
    }

    // MARK: Settings

    func setEnabled(_ enabled: Bool) async {
        card?.enabled = enabled
        await change { try await self.api.setEnabled(enabled) }
    }

    func setAgent(_ choice: AgentChoice?) async {
        card?.agent = choice
        await change { try await self.api.setAgent(choice) }
    }

    func addSkip(_ person: IMessagePerson) async {
        guard let card, !card.skip.contains(where: { $0.handle == person.handle }) else { return }
        let next = card.skip + [person]
        self.card?.skip = next
        await change { try await self.api.setSkip(next) }
    }

    func removeSkip(_ person: IMessagePerson) async {
        guard let card else { return }
        let next = card.skip.filter { $0.handle != person.handle }
        self.card?.skip = next
        await change { try await self.api.setSkip(next) }
    }

    // MARK: Chats

    func setTicked(_ chat: IMessageChat, _ on: Bool) async {
        if let index = card?.chats.firstIndex(where: { $0.guid == chat.guid }) {
            card?.chats[index].effective = on
            card?.chats[index].pick = on
        }
        await change { try await self.api.setPick(chat.guid, pick: on) }
    }

    func forget(_ chat: IMessageChat) async {
        do {
            let count = try await api.forget(chat.guid)
            toast = count == 1 ? "Forgot 1 memory" : "Forgot \(count) memories"
        } catch {
            toast = apiErrorMessage(error)
        }
        await refresh()
    }

    // MARK: Backfill

    /// `chats` nil = every ticked chat. Returns whether the server took it.
    @discardableResult
    func runBackfill(from: Date, to: Date, chats: [String]?) async -> Bool {
        guard to > from else {
            toast = "From has to be before To"
            return false
        }
        startingBackfill = true
        defer { startingBackfill = false }
        do {
            try await api.backfill(from: from, to: to, chats: chats)
            toast = "Backfill started"
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
        await refresh()
        return true
    }

    func stop(_ job: IMessageBackfillJob) async {
        do {
            try await api.stop(job.id)
            toast = "Stopping"
        } catch {
            toast = apiErrorMessage(error)
        }
        await refresh()
    }

    // MARK: Helpers

    /// Sends a change the screen already shows; the reply is the truth. A failure says
    /// why and puts the server's copy back.
    private func change(_ work: @escaping () async throws -> IMessageMemoryCard) async {
        do {
            apply(try await work())
            errorMessage = nil
        } catch {
            toast = apiErrorMessage(error)
            await refresh()
        }
    }
}
