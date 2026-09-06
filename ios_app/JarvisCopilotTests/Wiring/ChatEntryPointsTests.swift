import XCTest
@testable import JarvisCopilot

/// How Chat is reached from outside itself: Siri's "Ask JARVIS", the
/// `jarviscopilot://chat?session=` deep link, and the on-device lane the screen
/// has to be built with.
///
/// These live on ``ChatStore`` rather than inside `ChatPage`'s `.task` precisely
/// so they can be asserted — a SwiftUI `.task` does not run under a test's layout
/// pass, which is how this wiring went missing in the first place.
@MainActor
final class ChatEntryPointsTests: XCTestCase {

    private func makeStore() -> (ChatStore, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/sessions", json: ["sessions": []])
        return (ChatStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore())),
                transport)
    }

    // MARK: The on-device lane

    /// Without a handler every turn goes to the server, whatever the on-device AI
    /// settings say — which is exactly the bug this catches.
    func testTheProductionStoreCarriesTheOnDeviceHandler() {
        let (api, _) = JarvisAPI.mocked()
        XCTAssertTrue(ChatStore.production(api: api).usesOnDeviceLane)
    }

    func testAStoreBuiltWithoutOneIsServerOnly() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.usesOnDeviceLane)
    }

    // MARK: "Ask JARVIS"

    func testAdoptingTheLaunchBusTakesOverSending() async {
        let (store, _) = makeStore()
        let bus = ChatLaunchBus()
        await store.adoptChatLaunch(bus)
        XCTAssertNotNil(bus.send, "the open thread, not the AppServices fallback, owns the bus now")
    }

    /// A cold launch runs the intent before any page exists, so the bus latches.
    /// Mounting the screen has to drain that latch or the prompt is lost.
    func testAPromptLatchedBeforeTheScreenExistedIsDrained() async {
        let (store, _) = makeStore()
        let bus = ChatLaunchBus()
        bus.request("when is my flight")
        XCTAssertEqual(bus.pendingPrompt, "when is my flight")

        await store.adoptChatLaunch(bus)

        XCTAssertNil(bus.pendingPrompt, "the latch is taken exactly once")
        XCTAssertEqual(store.messages.first?.plainText, "when is my flight",
                       "the prompt has to land in the thread the user is looking at")
    }

    func testAdoptingAnEmptyBusSendsNothing() async {
        let (store, _) = makeStore()
        await store.adoptChatLaunch(ChatLaunchBus())
        XCTAssertTrue(store.messages.isEmpty)
    }

    // MARK: The chat deep link

    func testTheDeepLinkTargetOpensThatSession() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/sessions", json: ["sessions": []])
        transport.route("/api/sessions/s-9",
                        json: ["session": ["id": "s-9", "title": "Flights"], "messages": []])
        let store = ChatStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore()))

        let targets = DeepLinkTargets()
        targets.requestChat(session: "s-9")
        await store.openDeepLinkTarget(targets)

        XCTAssertEqual(store.sessionID, "s-9")
        XCTAssertNil(targets.consumeChat(), "a latch, taken exactly once")
    }

    func testNoPendingTargetIsANoOp() async {
        let (store, transport) = makeStore()
        await store.openDeepLinkTarget(DeepLinkTargets())
        XCTAssertNil(store.sessionID)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// `jarviscopilot://chat` with no session id means "just show Chat"; it must
    /// not blow away the thread the user already has open.
    func testASessionlessLinkDoesNotReopenAnything() async {
        let (store, _) = makeStore()
        store.sessionID = "already-open"
        let targets = DeepLinkTargets()
        targets.requestChat(session: nil)
        await store.openDeepLinkTarget(targets)
        XCTAssertEqual(store.sessionID, "already-open")
    }
}
