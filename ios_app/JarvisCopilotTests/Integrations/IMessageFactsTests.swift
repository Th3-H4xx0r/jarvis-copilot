import Foundation
import UserNotifications
import XCTest
@testable import JarvisCopilot

/// iMessage fact cards + chat previews: the `/facts` and `/preview` replies, the
/// `IMESSAGE_FACTS` push (burst key, Store all / Skip all), and the home cards.
@MainActor
final class IMessageFactsTests: XCTestCase {

    // MARK: Decoding

    func testTheFactsListDecodes() throws {
        let json = """
        {"facts": [
          {"id": "f2", "guid": "iMessage;-;+15550001", "chat_name": "Sam Lee",
           "fact": "Sam's sister is called Ana.", "at": 1760900000.5, "expires_at": 1760986400.5},
          {"id": "f1", "guid": "chat9", "fact": "Dinner moved to Friday.", "at": 1760800000}
        ]}
        """
        let facts = try IMessageFact.decodeList(Data(json.utf8))
        XCTAssertEqual(facts.map(\.id), ["f2", "f1"], "the server's order (newest first) is kept")
        XCTAssertEqual(facts[0].chatName, "Sam Lee")
        XCTAssertEqual(facts[0].guid, "iMessage;-;+15550001")
        XCTAssertEqual(facts[0].at, 1760900000.5)
        XCTAssertEqual(facts[0].expiresAt, 1760986400.5)
        XCTAssertEqual(facts[1].chatName, "", "a missing field reads as empty")
        XCTAssertEqual(facts[1].expiresAt, 0)
        XCTAssertEqual(try IMessageFact.decodeList(Data("{}".utf8)), [])
    }

    func testAFactSaysWhereAndWhen() {
        let now = Date(timeIntervalSince1970: 1_760_900_000)
        let fact = IMessageFact(id: "f", chatName: "Sam Lee", fact: "x", at: now.timeIntervalSince1970 - 10)
        XCTAssertEqual(fact.source(now: now), "from Sam Lee · just now")
        let older = IMessageFact(id: "g", chatName: "Sam Lee", fact: "x", at: now.timeIntervalSince1970 - 7_200)
        XCTAssertTrue(older.source(now: now).hasPrefix("from Sam Lee · "))
        XCTAssertNotEqual(older.source(now: now), "from Sam Lee · just now")
    }

    func testThePreviewDecodesOldestFirst() throws {
        let json = """
        {"messages": [
          {"ts": 1760900000, "sender": "Sam Lee", "is_from_me": false, "text": "Your code is [code hidden]"},
          {"ts": 1760900060, "sender": "", "is_from_me": true, "text": "Thanks"}
        ]}
        """
        let messages = try IMessagePreviewMessage.decodeList(Data(json.utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].sender, "Sam Lee")
        XCTAssertFalse(messages[0].isFromMe)
        XCTAssertEqual(messages[0].text, "Your code is [code hidden]")
        XCTAssertTrue(messages[1].isFromMe)
        XCTAssertEqual(messages[1].ts, 1760900060)
        XCTAssertEqual(try IMessagePreviewMessage.decodeList(Data("{}".utf8)), [])
    }

    func testAPreviewFailureShowsTheServersWords() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/imessage-memory/preview", json: ["error": "Your Mac didn't answer — is it awake?"],
                        status: 504)
        do {
            _ = try await IMessageMemoryAPI(api: client).preview("iMessage;-;+15550001")
            XCTFail("a 504 must throw")
        } catch {
            XCTAssertEqual(apiErrorLine(error), "Your Mac didn't answer — is it awake?")
        }
        // A "+" in the guid survives the server's query parsing (it'd be a space otherwise).
        let query = try XCTUnwrap(transport.lastRequest?.url?.query)
        XCTAssertTrue(query.contains("%2B15550001"), query)
        XCTAssertFalse(query.contains("+"), query)
    }

    // MARK: The push

    private func userInfo(burst: String? = "chat9|1234") -> [AnyHashable: Any] {
        var env: [String: Any] = ["type": "imessage_facts"]
        if let burst { env["burst"] = burst }
        return ["aps": ["category": "IMESSAGE_FACTS"], "jarviscopilot": env]
    }

    func testTheBurstKeyComesFromTheEnvelope() {
        XCTAssertEqual(IMessageFactsPush.burst(from: userInfo()), "chat9|1234")
        XCTAssertTrue(IMessageFactsPush.isFactsPush(userInfo()))
        XCTAssertNil(IMessageFactsPush.burst(from: userInfo(burst: nil)))
        XCTAssertNil(IMessageFactsPush.burst(from: userInfo(burst: "  ")))
        XCTAssertNil(IMessageFactsPush.burst(from: ["burst": "chat9|1"]), "only inside the envelope")
        XCTAssertFalse(IMessageFactsPush.isFactsPush(["jarviscopilot": ["kind": "mac_paused"]]))
    }

    func testStoreAllAndSkipAllMapToTheStoreFlag() {
        XCTAssertEqual(IMessageFactsPush.store(forAction: "IMESSAGE_FACTS_STORE"), true)
        XCTAssertEqual(IMessageFactsPush.store(forAction: "IMESSAGE_FACTS_SKIP"), false)
        XCTAssertNil(IMessageFactsPush.store(forAction: UNNotificationDefaultActionIdentifier))

        let store = NotificationAction.decode(actionIdentifier: "IMESSAGE_FACTS_STORE", userInfo: userInfo())
        XCTAssertEqual(store.verdict, .storeFacts)
        XCTAssertEqual(store.burst, "chat9|1234")
        XCTAssertEqual(store.kind, "imessage_facts")
        XCTAssertEqual(NotificationAction.decode(actionIdentifier: "IMESSAGE_FACTS_SKIP", userInfo: userInfo()).verdict,
                       .skipFacts)
    }

    func testTheCategoryAnswersFromTheLockScreen() throws {
        let category = try XCTUnwrap(NotificationCategories.all().first { $0.identifier == "IMESSAGE_FACTS" })
        XCTAssertEqual(category.actions.map(\.identifier), ["IMESSAGE_FACTS_STORE", "IMESSAGE_FACTS_SKIP"])
        XCTAssertEqual(category.actions.map(\.title), ["Store all", "Skip all"])
        for action in category.actions {
            XCTAssertFalse(action.options.contains(.foreground), action.identifier)
            XCTAssertFalse(action.options.contains(.authenticationRequired), action.identifier)
        }
        XCTAssertTrue(NotificationCategories.all().contains { $0.identifier == "MAC_SLEPT" }, "the others stay")
    }

    private func handler(_ client: JarvisAPI, router: AppRouter, notifier: MockNotifier = MockNotifier())
        -> NotificationActionHandler {
        NotificationActionHandler(coding: CodingSessionsAPI(api: client),
                                  router: AppDeepLinkRouter(router: router, targets: DeepLinkTargets()),
                                  pending: PendingActions(), notifier: notifier,
                                  facts: IMessageMemoryAPI(api: client))
    }

    func testStoreAllPostsTheBurstWithStoreTrue() async throws {
        for (identifier, expected) in [("IMESSAGE_FACTS_STORE", true), ("IMESSAGE_FACTS_SKIP", false)] {
            let (client, transport) = JarvisAPI.mocked()
            transport.route("/api/imessage-memory/facts/decide", json: ["ok": true, "decided": 2])
            let action = NotificationAction.decode(actionIdentifier: identifier, userInfo: userInfo())
            await handler(client, router: AppRouter()).handle(action)
            XCTAssertEqual(transport.lastRequest?.url?.path, "/api/imessage-memory/facts/decide")
            let body = transport.lastBody()
            XCTAssertEqual(body["burst"] as? String, "chat9|1234")
            XCTAssertEqual(body["store"] as? Bool, expected, identifier)
            XCTAssertNil(body["ids"])
        }
    }

    func testTappingTheFactsPushOpensTheChatTab() async {
        let (client, _) = JarvisAPI.mocked()
        let router = AppRouter()
        router.selectedTab = .agents
        let tap = NotificationAction.decode(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                            userInfo: userInfo())
        XCTAssertEqual(tap.verdict, .open)
        await handler(client, router: router).handle(tap)
        XCTAssertEqual(router.selectedTab, .chat)
    }

    // MARK: Home cards

    func testAnsweringACardRemovesItAndAFailurePutsItBack() async throws {
        let (client, transport) = JarvisAPI.mocked()
        // Path-substring routes, first match wins: the longer path goes first.
        transport.route("/api/imessage-memory/facts/decide", json: ["ok": true, "decided": 1])
        transport.route("/api/imessage-memory/facts", json: ["facts": [
            ["id": "f2", "chat_name": "Sam", "fact": "B", "at": 2.0],
            ["id": "f1", "chat_name": "Sam", "fact": "A", "at": 1.0],
        ]])
        let store = IMessageFactsStore(api: IMessageMemoryAPI(api: client))
        await store.refresh()
        XCTAssertEqual(store.facts.map(\.id), ["f2", "f1"])

        await store.decide(store.facts[0], store: true)
        XCTAssertEqual(transport.lastBody()["ids"] as? [String], ["f2"])
        XCTAssertEqual(transport.lastBody()["store"] as? Bool, true)
        XCTAssertEqual(store.facts.map(\.id), ["f1"])
        XCTAssertNil(store.toast)
    }

    func testAFailedAnswerRestoresTheCardWithAToast() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/imessage-memory/facts/decide", json: ["error": "boom"], status: 500)
        transport.route("/api/imessage-memory/facts", json: ["facts": [
            ["id": "f2", "fact": "B"], ["id": "f1", "fact": "A"],
        ]])
        let store = IMessageFactsStore(api: IMessageMemoryAPI(api: client))
        await store.refresh()
        await store.decide(store.facts[0], store: false)
        XCTAssertEqual(store.facts.map(\.id), ["f2", "f1"], "back where it was")
        XCTAssertTrue(store.toast?.contains("boom") == true, store.toast ?? "")
    }

    func testAnOldServerWithoutFactsShowsNoCards() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/imessage-memory/facts", json: ["error": "not found"], status: 404)
        let store = IMessageFactsStore(api: IMessageMemoryAPI(api: client))
        await store.refresh()
        XCTAssertEqual(store.facts, [])
        XCTAssertNil(store.toast)
    }
}
