import XCTest
@testable import JarvisCopilot

/// A fake Game Streaming API that records the calls and returns canned outcomes.
final class FakeGameStreamingAPI: GameStreamingAPI {
    var statusValue: GameStreamingStatus
    var startOutcome: GameStartOutcome = .started(note: nil)
    var pairOutcome: GamePairOutcome = .paired(detail: nil)
    private(set) var startCalls: [(target: String, game: String)] = []
    private(set) var pairCalls: [(device: String, pin: String)] = []
    private(set) var unpairCalls: [String] = []
    private(set) var stopCalls = 0

    init(status: GameStreamingStatus) { statusValue = status }

    func status() async throws -> GameStreamingStatus { statusValue }
    func start(target: String, game: String) async throws -> GameStartOutcome {
        startCalls.append((target, game)); return startOutcome
    }
    func stop(target: String?) async throws { stopCalls += 1 }
    func pair(device: String, pin: String) async throws -> GamePairOutcome {
        pairCalls.append((device, pin)); return pairOutcome
    }
    func unpair(device: String) async throws { unpairCalls.append(device) }
}

@MainActor
final class GameStreamingPageTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "game-streaming-tests-\(UUID().uuidString)")
    }

    private func sampleStatus(reachable: Bool = true) -> GameStreamingStatus {
        GameStreamingStatus(
            ok: true, reachable: reachable,
            live: GameLive(active: false),
            paired: [GamePaired(name: "Mac", uuid: "abc-123")],
            apps: [GameApp(name: "Hades"), GameApp(name: "Celeste")],
            targets: [GameTarget(name: "Mac", kind: "mac", host: "gpc"),
                      GameTarget(name: "TV", kind: "androidtv", host: "10.0.0.5")])
    }

    func testRefreshListsTargetsGamesAndPicksDefault() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus())
        let store = GameStreamingStore(client: fake, defaults: defaults)
        await store.refresh()
        XCTAssertEqual(store.status?.targets.map(\.name), ["Mac", "TV"])
        XCTAssertEqual(store.status?.apps.map(\.name), ["Hades", "Celeste"])
        XCTAssertEqual(store.chosenGame, "Hades")   // first game by default
        XCTAssertNil(store.error)
    }

    func testStartCallsClientAndRecordsRecent() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus())
        let store = GameStreamingStore(client: fake, defaults: defaults)
        let result = await store.start(target: "Mac", game: "Hades")
        XCTAssertEqual(result, .ok(nil))
        XCTAssertEqual(fake.startCalls.map(\.target), ["Mac"])
        XCTAssertEqual(fake.startCalls.map(\.game), ["Hades"])
        XCTAssertEqual(store.lastRecent?.game, "Hades")
        XCTAssertEqual(store.lastRecent?.target, "Mac")
    }

    func testPendingStartSaysPending() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus(reachable: false))
        fake.startOutcome = .pending
        let store = GameStreamingStore(client: fake, defaults: defaults)
        let result = await store.start(target: "Mac", game: "Hades")
        if case .ok(let note) = result {
            XCTAssertEqual(note, "Pending — it'll connect when the PC is up")
        } else {
            XCTFail("expected a pending ok, got \(result)")
        }
    }

    func testRecentsLeadWithTheLastStreamAndDedupe() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus())
        let store = GameStreamingStore(client: fake, defaults: defaults)
        _ = await store.start(target: "Mac", game: "Hades")
        _ = await store.start(target: "TV", game: "Celeste")
        _ = await store.start(target: "Mac", game: "Hades")   // same pair again
        XCTAssertEqual(store.recents.count, 2)
        XCTAssertEqual(store.recents.first?.game, "Hades")
        XCTAssertEqual(store.recents.first?.target, "Mac")
    }

    func testRecentsPersistAcrossStores() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus())
        let store = GameStreamingStore(client: fake, defaults: defaults)
        _ = await store.start(target: "TV", game: "Celeste")
        let reopened = GameStreamingStore(client: FakeGameStreamingAPI(status: sampleStatus()), defaults: defaults)
        XCTAssertEqual(reopened.lastRecent?.game, "Celeste")
        XCTAssertEqual(reopened.lastRecent?.target, "TV")
    }

    func testPairPostsThePIN() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus())
        let store = GameStreamingStore(client: fake, defaults: defaults)
        let outcome = await store.pair(device: "Living Room TV", pin: "4827")
        XCTAssertEqual(outcome, .paired(detail: nil))
        XCTAssertEqual(fake.pairCalls.count, 1)
        XCTAssertEqual(fake.pairCalls.first?.device, "Living Room TV")
        XCTAssertEqual(fake.pairCalls.first?.pin, "4827")
    }

    func testPairOfflineComesBackAsOffline() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus(reachable: false))
        fake.pairOutcome = .offline("The PC is asleep or offline")
        let store = GameStreamingStore(client: fake, defaults: defaults)
        let outcome = await store.pair(device: "TV", pin: "0000")
        XCTAssertEqual(outcome, .offline("The PC is asleep or offline"))
    }

    func testUnpairUsesTheUUID() async {
        let fake = FakeGameStreamingAPI(status: sampleStatus())
        let store = GameStreamingStore(client: fake, defaults: defaults)
        await store.refresh()
        let device = try! XCTUnwrap(store.status?.paired.first)
        _ = await store.unpair(device)
        XCTAssertEqual(fake.unpairCalls, ["abc-123"])
    }
}
