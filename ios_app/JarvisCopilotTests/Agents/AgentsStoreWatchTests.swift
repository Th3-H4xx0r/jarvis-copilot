import XCTest
@testable import JarvisCopilot

/// The PC page and the Agents tab both show the PC card's controls: the list is pushed while either is open.
@MainActor
final class AgentsStoreWatchTests: XCTestCase {
    func testListIsWantedWhileAnyOwnerWatches() {
        let topics = BridgeTopics()
        topics.send = { _ in }
        let store = AgentsStore(topics: topics)
        store.watch("agents-tab", true)
        store.watch("pc", true)
        store.watch("agents-tab", false)
        XCTAssertNotNil(topics.topics[AgentsStore.topic])
        store.watch("pc", false)
        XCTAssertNil(topics.topics[AgentsStore.topic])
    }

    func testSetVisibleStillWorks() {
        let topics = BridgeTopics()
        topics.send = { _ in }
        let store = AgentsStore(topics: topics)
        store.setVisible(true)
        XCTAssertNotNil(topics.topics[AgentsStore.topic])
        store.setVisible(false)
        XCTAssertNil(topics.topics[AgentsStore.topic])
    }
}
