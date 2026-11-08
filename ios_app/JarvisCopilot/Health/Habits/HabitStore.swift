import Foundation

/// What Jarvis Health keeps of the habits being quit.
struct HabitSnapshot: Codable, Equatable {
    var habits: [Habit]
    var relapses: [HabitRelapse]
}

/// The server side of `HabitStore`, so tests can stand in for it.
@MainActor
protocol HabitSyncing: AnyObject {
    func snapshot() async throws -> HabitSnapshot
    func put(habit: Habit) async throws
    func deleteHabit(id: String) async throws
    func put(relapse: HabitRelapse) async throws
    func deleteRelapse(uid: String) async throws
}

/// Jarvis Health's habit endpoints (`/health/habits*`).
@MainActor
final class HealthHabitSync: HabitSyncing {
    private let client: HealthClient

    init(client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) {
        self.client = client
    }

    func snapshot() async throws -> HabitSnapshot {
        let object = try await client.api.get("\(client.base)/habits", query: ["relapses": "1"]).object()
        return HabitSnapshot(habits: try HealthClient.decode([Habit].self, from: object["habits"] ?? []),
                             relapses: try HealthClient.decode([HabitRelapse].self, from: object["relapses"] ?? []))
    }

    func put(habit: Habit) async throws {
        _ = try await client.api.post("\(client.base)/habits", json: ["habit": try HealthClient.serverJSON(habit)])
    }

    func deleteHabit(id: String) async throws {
        _ = try await client.api.post("\(client.base)/habits/delete", json: ["id": id])
    }

    func put(relapse: HabitRelapse) async throws {
        _ = try await client.api.post("\(client.base)/habits/relapse", json: try HealthClient.serverJSON(relapse))
    }

    func deleteRelapse(uid: String) async throws {
        _ = try await client.api.post("\(client.base)/habits/relapse/delete", json: ["uid": uid])
    }
}

/// A change made on the phone, waiting to reach the server.
enum HabitOp: Codable, Equatable {
    case putHabit(Habit)
    case deleteHabit(String)
    case putRelapse(HabitRelapse)
    case deleteRelapse(String)

    /// The habit it belongs to, so deleting a habit can drop what was queued for it.
    var habitID: String? {
        switch self {
        case .putHabit(let h): return h.id
        case .deleteHabit(let id): return id
        case .putRelapse(let r): return r.habit
        case .deleteRelapse: return nil
        }
    }
}

/// The habits being quit, kept on the phone so a card and a 3-second hold
/// work at once, even with no signal. Every change goes to Jarvis Health
/// through a queue that survives a failed send; the server's copy (which chat
/// edits too) replaces the phone's whenever nothing is waiting to be sent.
@MainActor
final class HabitStore: ObservableObject {
    static let shared = HabitStore(sync: HealthHabitSync(), topics: .shared)

    @Published private(set) var habits: [Habit] = []
    /// Every relapse, oldest first.
    @Published private(set) var relapses: [HabitRelapse] = []
    /// Why the server refused the last change, shown under the cards.
    @Published var error: String?
    var queue: [HabitOp] { outbox.ops }
    /// Send each change as it is made; tests turn this off to drive `flush`.
    var sendsAtOnce = true

    private let files: JSONFolder
    private let outbox: HealthOutbox<HabitOp>
    private let sync: HabitSyncing?
    private let topics: BridgeTopics?
    /// Bumped by every change made here, so a refresh can tell its snapshot went stale in flight.
    private var revision = 0
    init(directory: URL? = nil, sync: HabitSyncing?, topics: BridgeTopics? = nil) {
        files = JSONFolder(directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habits", isDirectory: true), label: "habit file")
        outbox = HealthOutbox(files, label: "habit sync")
        self.sync = sync
        self.topics = topics
        habits = files.read([Habit].self, "habits") ?? []
        relapses = files.read([HabitRelapse].self, "relapses") ?? []
        topics?.on("habits") { [weak self] _ in Task { await self?.refresh() } }
        // Back online: what was logged offline goes now, page open or not; a
        // page that is open fetches what chat changed meanwhile.
        topics?.onResync { [weak self] in
            guard let self else { return }
            Task {
                if self.topics?.isWanted("habits") == true { await self.refresh() } else { await self.flush() }
            }
        }
    }

    func relapses(of habitID: String) -> [HabitRelapse] {
        relapses.filter { $0.habit == habitID }
    }

    // MARK: Changes

    func save(_ habit: Habit) {
        var habit = habit
        habit.timezone = TimeZone.current.identifier
        if let i = habits.firstIndex(where: { $0.id == habit.id }) {
            habits[i] = habit
        } else {
            habits.append(habit)
        }
        files.write(habits, "habits")
        enqueue(.putHabit(habit))
    }

    func delete(_ habit: Habit) {
        habits.removeAll { $0.id == habit.id }
        relapses.removeAll { $0.habit == habit.id }
        outbox.removeAll { $0.habitID == habit.id }
        files.write(habits, "habits")
        files.write(relapses, "relapses")
        enqueue(.deleteHabit(habit.id))
    }

    @discardableResult
    func log(_ habit: Habit, at: Date = Date(), note: String? = nil) -> HabitRelapse {
        let relapse = HabitRelapse(habit: habit.id, uid: UUID().uuidString.lowercased(), at: at.wholeSeconds,
                                   tz: TimeZone.current.identifier, note: note)
        relapses.append(relapse)
        relapses.sort { $0.at < $1.at }
        files.write(relapses, "relapses")
        enqueue(.putRelapse(relapse))
        return relapse
    }

    func undo(_ relapse: HabitRelapse) {
        relapses.removeAll { $0.uid == relapse.uid }
        files.write(relapses, "relapses")
        // Not sent yet: it never goes. Either way the server is asked to delete it — a
        // send in flight, or one that timed out here after the server stored it, may
        // have reached it, and deleting a relapse it never had is harmless.
        let inFlight = outbox.isSending && queue.first == .putRelapse(relapse)
        if !inFlight { outbox.removeAll { $0 == .putRelapse(relapse) } }
        enqueue(.deleteRelapse(relapse.uid))
    }

    // MARK: Server

    /// The Habits pages say they are open, so chat's changes are pushed here.
    func want(_ owner: String) { topics?.want("habits", owner: owner) }
    func drop(_ owner: String) { topics?.drop("habits", owner: owner) }

    private func enqueue(_ op: HabitOp) {
        revision += 1
        outbox.append(op)
        if sendsAtOnce { Task { await flush() } }
    }

    /// Send what is waiting, in order. A refusal drops that change and says
    /// why; anything else (offline, a 5xx, a 401) stops and keeps the rest.
    func flush() async {
        guard let sync else { return }
        await outbox.flush(send: { op in
            switch op {
            case .putHabit(let h): try await sync.put(habit: h)
            case .deleteHabit(let id): try await sync.deleteHabit(id: id)
            case .putRelapse(let r): try await sync.put(relapse: r)
            case .deleteRelapse(let uid): try await sync.deleteRelapse(uid: uid)
            }
        }, refused: { [weak self] status, message in
            self?.error = message.isEmpty ? "Jarvis Health refused a change (\(status))" : message
        })
    }

    /// Send what is waiting, then take the server's copy — unless something
    /// could not be sent, or changed here while it was fetched.
    func refresh() async {
        guard let sync else { return }
        await flush()
        guard queue.isEmpty else { return }
        let before = revision
        guard let snapshot = try? await sync.snapshot(), revision == before, queue.isEmpty else { return }
        error = nil
        habits = snapshot.habits
        relapses = snapshot.relapses.sorted { $0.at < $1.at }
        files.write(habits, "habits")
        files.write(relapses, "relapses")
    }

}
