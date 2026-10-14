import XCTest
@testable import JarvisCopilot

/// A stand-in for Jarvis Health's habit endpoints.
@MainActor
final class FakeHabitSync: HabitSyncing {
    var calls: [String] = []
    /// Offline: every call throws.
    var failing = false
    /// The server refuses (a habit chat deleted, a bad field).
    var rejecting = false
    var snapshot = HabitSnapshot(habits: [], relapses: [])

    private func call(_ name: String) throws {
        if failing { throw URLError(.notConnectedToInternet) }
        if rejecting { throw APIError.http(status: 404, message: "no habit 'gone'") }
        calls.append(name)
    }

    func snapshot() async throws -> HabitSnapshot { try call("snapshot"); return snapshot }
    func put(habit: Habit) async throws { try call("put \(habit.name)") }
    func deleteHabit(id: String) async throws { try call("delete \(id)") }
    func put(relapse: HabitRelapse) async throws { try call("relapse \(relapse.habit)") }
    func deleteRelapse(uid: String) async throws { try call("undo") }
}

/// Habits kept on the phone for the moment they are needed, and sent to
/// Jarvis Health when they can be.
@MainActor
final class HabitStoreTests: XCTestCase {
    private var directory: URL!
    private var sync: FakeHabitSync!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HabitStoreTests-\(UUID().uuidString)")
        sync = FakeHabitSync()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(topics: BridgeTopics? = nil) -> HabitStore {
        let store = HabitStore(directory: directory, sync: sync, topics: topics)
        store.sendsAtOnce = false
        return store
    }

    private let vape = Habit(id: "vape", name: "Vape", startedAt: Date(timeIntervalSince1970: 1_790_000_000))

    func testALogShowsAtOnceAndSurvivesARelaunch() {
        let s = store()
        s.save(vape)
        let logged = s.log(vape, at: Date(timeIntervalSince1970: 1_790_100_000))
        XCTAssertEqual(s.relapses(of: "vape"), [logged])
        XCTAssertEqual(logged.tz, TimeZone.current.identifier)
        let again = store()
        XCTAssertEqual(again.habits.map(\.id), ["vape"])
        XCTAssertEqual(again.relapses(of: "vape"), [logged])
        XCTAssertEqual(again.queue.count, 2)
    }

    func testAFailedSendKeepsTheQueueAndSendsEachOpOnce() async {
        let s = store()
        s.save(vape)
        s.log(vape)
        sync.failing = true
        await s.flush()
        XCTAssertEqual(s.queue.count, 2)
        sync.failing = false
        await s.flush()
        XCTAssertEqual(sync.calls, ["put Vape", "relapse vape"])
        XCTAssertTrue(s.queue.isEmpty)
        await s.flush()
        XCTAssertEqual(sync.calls.count, 2)
    }

    func testARefusedSendIsDroppedAndSaysWhy() async {
        let s = store()
        s.log(vape)
        sync.rejecting = true
        await s.flush()
        XCTAssertTrue(s.queue.isEmpty)
        XCTAssertEqual(s.error, "no habit 'gone'")
    }

    func testUndoingAnUnsentRelapseNeverReachesTheServer() async {
        let s = store()
        let logged = s.log(vape)
        s.undo(logged)
        XCTAssertTrue(s.relapses(of: "vape").isEmpty)
        await s.flush()
        XCTAssertEqual(sync.calls, [])
    }

    func testUndoingASentRelapseDeletesItThere() async {
        let s = store()
        let logged = s.log(vape)
        await s.flush()
        s.undo(logged)
        await s.flush()
        XCTAssertEqual(sync.calls, ["relapse vape", "undo"])
    }

    func testRefreshTakesTheServersCopyOnlyWhenNothingIsWaiting() async {
        let s = store()
        let mine = s.log(vape, at: Date(timeIntervalSince1970: 1_790_100_000))
        sync.failing = true
        await s.refresh()
        XCTAssertEqual(s.relapses(of: "vape"), [mine])       // offline: the phone's copy stands
        sync.failing = false
        let theirs = HabitRelapse(habit: "vape", uid: "chat-1", at: Date(timeIntervalSince1970: 1_790_200_000), tz: "UTC")
        sync.snapshot = HabitSnapshot(habits: [vape], relapses: [mine, theirs])
        await s.refresh()
        XCTAssertEqual(s.relapses(of: "vape").map(\.uid), [mine.uid, "chat-1"])
        XCTAssertEqual(s.habits, [vape])
    }

    func testDeletingAHabitDropsWhatWasQueuedForIt() async {
        let s = store()
        s.save(vape)
        s.log(vape)
        s.delete(vape)
        XCTAssertTrue(s.habits.isEmpty && s.relapses.isEmpty)
        await s.flush()
        XCTAssertEqual(sync.calls, ["delete vape"])
    }

    func testAHabitsPushRefreshes() async throws {
        let topics = BridgeTopics()
        topics.send = { _ in }
        let s = store(topics: topics)
        sync.snapshot = HabitSnapshot(habits: [vape], relapses: [])
        topics.deliver(["topic": "habits", "data": ["what": ["habits"]]])
        for _ in 0..<50 where s.habits.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(s.habits, [vape])
        s.want("habits-list")
        XCTAssertTrue(topics.isWanted("habits"))
        s.drop("habits-list")
        XCTAssertFalse(topics.isWanted("habits"))
    }
}
