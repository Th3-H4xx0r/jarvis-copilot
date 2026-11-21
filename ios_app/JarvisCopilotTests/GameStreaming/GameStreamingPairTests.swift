import XCTest
@testable import JarvisCopilot

/// Pairing against Sunshine's real API: the waiting-devices list, the auto-pick and
/// name prefill, the PIN sent with the request's pairing id, and the status store's
/// refresh guarantees (loading always clears, loads time out, overlapping loads share).
@MainActor
final class GameStreamingPairTests: XCTestCase {
    private let pid = "13270f21e5f70861ecdfd7ae0a10ff4f"
    private let pid2 = "0123456789abcdef0123456789abcdef"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "game-pair-tests-\(UUID().uuidString)")
    }

    private func status() -> GameStreamingStatus {
        GameStreamingStatus(ok: true, reachable: true, live: GameLive(), paired: [],
                            apps: [GameApp(name: "Desktop")], targets: [])
    }

    private func roth() -> GamePairing { GamePairing(id: pid, name: "roth", address: "192.168.1.69") }

    // MARK: decoding

    func testDecodesPairingsReply() {
        let r = GamePairingsReply(json: [
            "ok": true, "needs_login": false, "reachable": true,
            "pairings": [["id": pid, "name": "roth", "address": "192.168.1.69"], ["name": "no id"]],
        ])
        XCTAssertEqual(r.pairings, [roth()])                 // a row without an id is dropped
        XCTAssertFalse(r.needsLogin)
        XCTAssertTrue(r.reachable)
        XCTAssertTrue(GamePairingsReply(json: ["ok": true, "needs_login": true, "pairings": []]).needsLogin)
    }

    // MARK: selection + words

    func testSelectionAutoPicksTheOnlyWaitingDevice() {
        let other = GamePairing(id: pid2, name: "Shield")
        XCTAssertEqual(GamePairModel.selection(current: nil, in: [roth()]), pid)
        XCTAssertNil(GamePairModel.selection(current: nil, in: [roth(), other]))      // user picks
        XCTAssertEqual(GamePairModel.selection(current: pid2, in: [roth(), other]), pid2)
        XCTAssertNil(GamePairModel.selection(current: pid, in: []))                   // it went away
    }

    func testWaitingLine() {
        XCTAssertEqual(GamePairModel.waitingLine(GamePairingsReply()),
                       "Waiting for a device… On the device, open Moonlight and tap your PC")
        XCTAssertEqual(GamePairModel.waitingLine(GamePairingsReply(pairings: [roth()])),
                       "Enter the PIN shown on roth")
        XCTAssertEqual(GamePairModel.waitingLine(GamePairingsReply(reachable: false, offline: true)),
                       "Your PC is asleep or offline — wake it to pair")
        XCTAssertEqual(GamePairModel.waitingLine(GamePairingsReply(needsLogin: true)),
                       "Sunshine needs sign-in — check your password in Set up")
        XCTAssertEqual(GamePairModel.waitingLine(GamePairingsReply(reachable: false)),
                       "Sunshine isn't running on your PC")
    }

    // MARK: the pair sheet's store

    func testOneWaitingDeviceIsPickedAndItsNamePrefilled() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.pairingsValue = GamePairingsReply(pairings: [roth()])
        let pair = GamePairStore(store: GameStreamingStore(client: fake, defaults: defaults))
        await pair.load()
        XCTAssertEqual(pair.selectedID, pid)
        XCTAssertEqual(pair.device, "roth")
        XCTAssertFalse(pair.canPair)                          // no PIN yet
        pair.pin = "1234"
        XCTAssertTrue(pair.canPair)
    }

    func testATypedNameSurvivesTheNextPoll() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.pairingsValue = GamePairingsReply(pairings: [roth(), GamePairing(id: pid2, name: "Shield")])
        let pair = GamePairStore(store: GameStreamingStore(client: fake, defaults: defaults))
        await pair.load()
        XCTAssertNil(pair.selectedID)                         // two waiting: the user picks
        pair.select(pid2)
        XCTAssertEqual(pair.device, "Shield")
        pair.device = "Living Room TV"
        await pair.load()                                     // the 2 s poll
        XCTAssertEqual(pair.selectedID, pid2)
        XCTAssertEqual(pair.device, "Living Room TV")
    }

    func testSubmitSendsThePairingID() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.pairingsValue = GamePairingsReply(pairings: [roth()])
        let pair = GamePairStore(store: GameStreamingStore(client: fake, defaults: defaults))
        await pair.load()
        pair.pin = "4827"
        let outcome = await pair.submit()
        XCTAssertEqual(outcome, .paired(detail: nil))
        XCTAssertEqual(fake.pairCalls.count, 1)
        XCTAssertEqual(fake.pairCalls.first?.pairingID, pid)
        XCTAssertEqual(fake.pairCalls.first?.pin, "4827")
        XCTAssertEqual(fake.pairCalls.first?.device, "roth")
        XCTAssertNil(pair.error)
        XCTAssertFalse(pair.busy)
    }

    func testAWrongPinShowsTheServersWords() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.pairingsValue = GamePairingsReply(pairings: [roth()])
        let detail = "Sunshine didn't accept that PIN — check the PIN shown on the device and try again"
        fake.pairOutcome = .failed(detail)
        let pair = GamePairStore(store: GameStreamingStore(client: fake, defaults: defaults))
        await pair.load()
        pair.pin = "0000"
        _ = await pair.submit()
        XCTAssertEqual(pair.error, detail)
        XCTAssertFalse(pair.busy)
    }

    func testNothingIsSentWithoutAWaitingDevice() async {
        let fake = FakeGameStreamingAPI(status: status())
        let pair = GamePairStore(store: GameStreamingStore(client: fake, defaults: defaults))
        await pair.load()
        pair.device = "Mac"
        pair.pin = "1234"
        XCTAssertFalse(pair.canPair)
        let outcome = await pair.submit()
        XCTAssertNil(outcome)
        XCTAssertTrue(fake.pairCalls.isEmpty)
    }

    // MARK: status refresh guarantees (the endless-spinner fix)

    func testLoadingClearsWhenStatusThrows() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.statusError = APIError.http(status: 502, message: "Bad gateway")
        let store = GameStreamingStore(client: fake, defaults: defaults)
        await store.refresh()
        XCTAssertFalse(store.loading)
        XCTAssertNotNil(store.error)
    }

    func testAStuckStatusTimesOutAndClearsLoading() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.statusDelay = 5
        let store = GameStreamingStore(client: fake, defaults: defaults)
        store.loadTimeout = 0.2
        let started = Date()
        await store.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(store.loading)
        XCTAssertNotNil(store.error)
    }

    func testOverlappingRefreshesShareOneLoad() async {
        let fake = FakeGameStreamingAPI(status: status())
        fake.statusDelay = 0.2
        let store = GameStreamingStore(client: fake, defaults: defaults)
        async let a: Void = store.refresh()
        async let b: Void = store.refresh()
        _ = await (a, b)
        XCTAssertEqual(fake.statusCalls, 1)
        XCTAssertFalse(store.loading)
        XCTAssertNotNil(store.status)
    }

    func testAFreshRefreshDuringAStaleLoadLoadsAgain() async {
        // A poll is mid-flight with the old (rejected) login when Save lands: the save's
        // fresh refresh must not settle for that stale answer.
        let rejected = GameStreamingStatus(ok: true, reachable: false, needsLogin: true,
                                           live: GameLive(), paired: [], apps: [], targets: [])
        let fake = FakeGameStreamingAPI(status: rejected)
        fake.statusDelay = 0.3
        let store = GameStreamingStore(client: fake, defaults: defaults)
        async let poll: Void = store.refresh()
        try? await Task.sleep(nanoseconds: 50_000_000)
        fake.statusValue = status()                       // the login is fixed now
        await store.refresh(fresh: true)
        _ = await poll
        XCTAssertEqual(fake.statusCalls, 2)
        XCTAssertEqual(store.status?.reachable, true)
        XCTAssertEqual(store.status?.needsLogin, false)
        XCTAssertFalse(store.loading)
    }

    func testAFreshLoadPicksUpAFixedLogin() async {
        // The old login was rejected; after Save the next refresh must show the new state.
        let fake = FakeGameStreamingAPI(status: GameStreamingStatus(
            ok: true, reachable: false, needsLogin: true, live: GameLive(), paired: [], apps: [], targets: []))
        let store = GameStreamingStore(client: fake, defaults: defaults)
        await store.refresh()
        XCTAssertEqual(store.status?.needsLogin, true)
        fake.statusValue = status()
        await store.refresh()
        XCTAssertEqual(store.status?.reachable, true)
        XCTAssertEqual(store.status?.needsLogin, false)
    }
}
