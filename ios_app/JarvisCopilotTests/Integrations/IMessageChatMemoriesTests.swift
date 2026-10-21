import Foundation
import XCTest
@testable import JarvisCopilot

/// The preview sheet's Memories tab: the `/memories` reply, a conversation's
/// title / preview split, and the store's delete + Store / Skip round trips.
@MainActor
final class IMessageChatMemoriesTests: XCTestCase {

    private let guid = "iMessage;-;+15550001"

    private let fullJSON: [String: Any] = [
        "facts": [
            ["id": "m2", "text": "Sam's sister is called Ana.", "at": 1_760_900_000.5],
            ["id": "m1", "text": "Sam is vegetarian.", "at": 1_760_800_000],
        ],
        "conversations": [
            ["id": "c1", "text": "Dinner plans\nSam: Friday?\nMe: Works", "at": 1_760_700_000],
        ],
        "waiting": [
            ["id": "f9", "guid": "iMessage;-;+15550001", "chat_name": "Sam Lee", "fact": "Sam moves in May.",
             "at": 1_760_950_000, "expires_at": 1_761_036_400, "burst": "iMessage;-;+15550001|42"],
        ],
    ]

    // MARK: Decoding

    func testTheMemoriesPayloadDecodes() throws {
        let data = try JSONSerialization.data(withJSONObject: fullJSON)
        let memories = try IMessageChatMemories.decode(data)
        XCTAssertEqual(memories.facts.map(\.id), ["m2", "m1"], "the server's order (newest first) is kept")
        XCTAssertEqual(memories.facts[0].text, "Sam's sister is called Ana.")
        XCTAssertEqual(memories.facts[0].at, 1_760_900_000.5)
        XCTAssertEqual(memories.conversations.map(\.id), ["c1"])
        XCTAssertEqual(memories.waiting.map(\.id), ["f9"])
        XCTAssertEqual(memories.waiting[0].chatName, "Sam Lee")
        XCTAssertEqual(memories.waiting[0].fact, "Sam moves in May.")
        XCTAssertEqual(memories.waiting[0].expiresAt, 1_761_036_400)
        XCTAssertFalse(memories.isEmpty)
    }

    func testMissingListsReadAsEmpty() throws {
        let empty = try IMessageChatMemories.decode(Data("{}".utf8))
        XCTAssertEqual(empty, IMessageChatMemories())
        XCTAssertTrue(empty.isEmpty)

        let some = try IMessageChatMemories.decode(Data(#"{"facts": [{"id": "m1", "text": "x"}], "waiting": null}"#.utf8))
        XCTAssertEqual(some.facts, [IMessageMemoryEntry(id: "m1", text: "x", at: 0)], "a missing time reads as 0")
        XCTAssertEqual(some.conversations, [])
        XCTAssertEqual(some.waiting, [])
        XCTAssertFalse(some.isEmpty)
    }

    func testAConversationSplitsIntoTitleAndPreview() {
        let entry = IMessageMemoryEntry(id: "c", text: "\n  Dinner plans  \r\nSam: Friday?\n\nMe: Works\n\n")
        XCTAssertEqual(entry.title, "Dinner plans")
        XCTAssertEqual(entry.body, "Sam: Friday?\n\nMe: Works")
        let oneLine = IMessageMemoryEntry(id: "d", text: "Just a title")
        XCTAssertEqual(oneLine.title, "Just a title")
        XCTAssertEqual(oneLine.body, "")
        XCTAssertEqual(IMessageMemoryEntry(id: "e", text: "").title, "")
    }

    // MARK: The store

    /// A store loaded from `fullJSON`. `routes` go in first: the mock matches by path
    /// substring, first match wins, and `/memories` is inside `/memories/delete`.
    private func loadedStore(_ routes: (MockTransport) -> Void = { _ in })
        async -> (IMessageChatMemoriesStore, MockTransport) {
        let (client, transport) = JarvisAPI.mocked()
        routes(transport)
        transport.route("/api/imessage-memory/memories", json: fullJSON)
        let store = IMessageChatMemoriesStore(guid: guid, api: IMessageMemoryAPI(api: client))
        await store.load()
        return (store, transport)
    }

    func testLoadAsksForThisChat() async throws {
        let (store, transport) = await loadedStore()
        XCTAssertEqual(store.memories?.facts.count, 2)
        XCTAssertNil(store.errorMessage)
        let query = try XCTUnwrap(transport.lastRequest?.url?.query)
        XCTAssertTrue(query.contains("%2B15550001"), query)
    }

    func testAFailedFirstLoadShowsTheError() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/imessage-memory/memories", json: ["error": "Not set up"], status: 500)
        let store = IMessageChatMemoriesStore(guid: guid, api: IMessageMemoryAPI(api: client))
        await store.load()
        XCTAssertNil(store.memories)
        XCTAssertNotNil(store.errorMessage)
    }

    func testDeleteRemovesTheRowAndPostsItsID() async throws {
        let (store, transport) = await loadedStore {
            $0.route("/api/imessage-memory/memories/delete", json: ["ok": true, "deleted": true])
        }
        let fact = try XCTUnwrap(store.memories?.facts.first)
        await store.delete(fact, .fact)
        XCTAssertEqual(store.memories?.facts.map(\.id), ["m1"])
        XCTAssertEqual(transport.lastBody()["id"] as? String, "m2")
        XCTAssertNil(store.toast)

        // A reload that still has it (the server hadn't caught up) doesn't bring it back.
        await store.refresh()
        XCTAssertEqual(store.memories?.facts.map(\.id), ["m1"])
    }

    func testAFailedDeletePutsTheRowBackAndSaysWhy() async throws {
        let (store, _) = await loadedStore {
            $0.route("/api/imessage-memory/memories/delete", json: ["error": "Database locked"], status: 500)
        }
        let conversation = try XCTUnwrap(store.memories?.conversations.first)
        await store.delete(conversation, .conversation)
        XCTAssertEqual(store.memories?.conversations.map(\.id), ["c1"])
        XCTAssertNotNil(store.toast)
    }

    func testDecidingAWaitingCardDropsIt() async throws {
        let (store, transport) = await loadedStore()
        transport.route("/api/imessage-memory/facts/decide", json: ["ok": true, "decided": 1])
        let card = try XCTUnwrap(store.memories?.waiting.first)
        await store.decide(card, store: false)
        XCTAssertEqual(store.memories?.waiting, [])
        let body = transport.lastBody()
        XCTAssertEqual(body["ids"] as? [String], ["f9"])
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testStoringAWaitingCardReloads() async throws {
        let (store, transport) = await loadedStore()
        transport.route("/api/imessage-memory/facts/decide", json: ["ok": true, "decided": 1])
        let before = transport.requests.count
        let card = try XCTUnwrap(store.memories?.waiting.first)
        await store.decide(card, store: true)
        let paths = transport.requests.dropFirst(before).compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/imessage-memory/facts/decide", "/api/imessage-memory/memories"])
        XCTAssertEqual(store.memories?.waiting, [], "the reload doesn't bring the stored card back")
    }

    func testAFailedDecisionPutsTheCardBack() async throws {
        let (store, transport) = await loadedStore()
        transport.route("/api/imessage-memory/facts/decide", json: ["error": "nope"], status: 500)
        let card = try XCTUnwrap(store.memories?.waiting.first)
        await store.decide(card, store: true)
        XCTAssertEqual(store.memories?.waiting.map(\.id), ["f9"])
        XCTAssertNotNil(store.toast)
    }
}
