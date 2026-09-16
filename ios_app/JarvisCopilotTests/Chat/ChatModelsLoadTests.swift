import XCTest
@testable import JarvisCopilot

/// "Could not load models: cancelled" on the Chat screen at every launch.
///
/// Three views want the catalogue at launch — `ChatPage`, `ChatConversationView`
/// and the picker sheet — and SwiftUI cancels a `.task` whose view goes away
/// while the shell is still settling. The losing task reported its own
/// cancellation as a failure, in a red banner, over the chat.
@MainActor
final class ChatModelsLoadTests: XCTestCase {

    private func store(_ transport: ScriptedTransport) -> ChatStore {
        ChatStore(api: JarvisAPI(credentials: TestCredentials(), transport: transport),
                  selection: ModelSelection(store: MemoryKeyValueStore()))
    }

    func testACancelledFetchIsNotAnError() async {
        let transport = ScriptedTransport()
        transport.on("GET /api/models", .failing(CancellationError()))
        let store = self.store(transport)

        await store.loadModels()

        XCTAssertNil(store.error, "a cancelled load is housekeeping, not a failure")
        XCTAssertNil(store.models)
    }

    func testAURLCancellationIsNotAnErrorEither() async {
        let transport = ScriptedTransport()
        transport.on("GET /api/models",
                     .failing(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        let store = self.store(transport)

        await store.loadModels()

        XCTAssertNil(store.error)
    }

    /// The other half of the rule: a load that genuinely failed still speaks up,
    /// because an empty picker with no explanation is its own bug.
    func testARealFailureStillReports() async {
        let transport = ScriptedTransport()
        transport.on("GET /api/models",
                     .failing(NSError(domain: NSURLErrorDomain,
                                      code: NSURLErrorCannotConnectToHost)))
        let store = self.store(transport)

        await store.loadModels()

        XCTAssertNotNil(store.error, "a real failure with no catalogue must be visible")
    }

    /// Three views asking at once should make one request, not three — and one of
    /// them being cancelled must not take the catalogue down with it.
    func testConcurrentCallersShareOneRequest() async {
        let transport = ScriptedTransport()
        transport.on("GET /api/models", .json(["models": []]))
        let store = self.store(transport)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { @MainActor in await store.loadModels() } }
        }

        XCTAssertEqual(transport.log.filter { $0.contains("/api/models") }.count, 1,
                       "the catalogue fetch should be shared, not run once per view")
        XCTAssertNil(store.error)
    }
}

/// The predicate both of them lean on.
final class CancellationPredicateTests: XCTestCase {
    func testItRecognisesBothShapesOfCancellation() {
        XCTAssertTrue(wasCancelled(CancellationError()))
        XCTAssertTrue(wasCancelled(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    }

    func testItDoesNotSwallowRealFailures() {
        XCTAssertFalse(wasCancelled(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(wasCancelled(NSError(domain: "Other", code: NSURLErrorCancelled)))
    }

    /// The Integrations store had its own copy; it must stay in step.
    @MainActor
    func testTheIntegrationsAliasIsTheSameRule() {
        XCTAssertTrue(IntegrationsStore.wasCancelled(CancellationError()))
        XCTAssertFalse(IntegrationsStore.wasCancelled(NSError(domain: "Other", code: 1)))
    }
}
