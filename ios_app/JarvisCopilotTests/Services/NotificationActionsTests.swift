import Foundation
import XCTest
@testable import JarvisCopilot

/// Port of `services/notification_actions.dart` plus the payload half of the
/// Flutter `AppDelegate.userNotificationCenter(_:didReceive:…)`.
@MainActor
final class NotificationActionsTests: XCTestCase {

    private func envelope(requestID: String = "req-1", sessionID: String = "sess-1")
    -> [AnyHashable: Any] {
        ["jarviscopilot": ["request_id": requestID, "session_id": sessionID]]
    }

    // MARK: Decoding

    func testApproveDenyAndReplyMapToVerdicts() {
        let approve = NotificationAction.decode(
            actionIdentifier: NotificationAction.Identifier.approve, userInfo: envelope())
        XCTAssertEqual(approve.verdict, .allow)
        XCTAssertEqual(approve.requestID, "req-1")
        XCTAssertEqual(approve.sessionID, "sess-1")

        let deny = NotificationAction.decode(
            actionIdentifier: NotificationAction.Identifier.deny, userInfo: envelope())
        XCTAssertEqual(deny.verdict, .deny)

        let reply = NotificationAction.decode(
            actionIdentifier: NotificationAction.Identifier.reply,
            userInfo: envelope(), userText: "use ripgrep instead")
        XCTAssertEqual(reply.verdict, .reply)
        XCTAssertEqual(reply.text, "use ripgrep instead")
    }

    func testTappingTheBannerBodyIsOpenNotAVerdict() {
        let action = NotificationAction.decode(
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: envelope())
        XCTAssertEqual(action.verdict, .open)
        XCTAssertEqual(action.text, "", "typed text only belongs to a reply")
    }

    func testAnUnknownActionDegradesToOpen() {
        let action = NotificationAction.decode(actionIdentifier: "SOMETHING_NEW", userInfo: [:])
        XCTAssertEqual(action.verdict, .open)
        XCTAssertEqual(action.requestID, "")
    }

    func testADeferredSkillPayloadIsCarriedThrough() {
        let payload = notificationActionPayload(skill: "open_url", args: ["url": "https://x"])!
        let action = NotificationAction.decode(
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [DefaultNotifier.payloadKey: payload])
        XCTAssertEqual(action.deferredPayload, payload)
    }

    // MARK: Verdict request shape

    private func makeHandler(_ api: JarvisAPI, pending: PendingActions? = nil,
                             notifier: MockNotifier = MockNotifier())
    -> (NotificationActionHandler, AppRouter) {
        let pending = pending ?? PendingActions()
        let router = AppRouter()
        return (NotificationActionHandler(
            coding: CodingSessionsAPI(api: api),
            router: AppDeepLinkRouter(router: router, targets: DeepLinkTargets()),
            pending: pending, notifier: notifier), router)
    }

    func testApprovePostsAnAllowVerdict() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let (handler, _) = makeHandler(api)

        await handler.handle(NotificationAction(verdict: .allow, requestID: "req-1",
                                                sessionID: "sess-1", text: ""))

        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/coding/permission/verdict")
        let body = transport.lastBody()
        XCTAssertEqual(body["request_id"] as? String, "req-1")
        XCTAssertEqual(body["decision"] as? String, "allow")
        XCTAssertNil(body["message"])
    }

    func testDenyPostsADenyVerdict() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let (handler, _) = makeHandler(api)

        await handler.handle(NotificationAction(verdict: .deny, requestID: "req-2",
                                                sessionID: "", text: ""))
        XCTAssertEqual(transport.lastBody()["decision"] as? String, "deny")
    }

    func testReplyIsADenyCarryingTheSteeringMessage() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let (handler, _) = makeHandler(api)

        await handler.handle(NotificationAction(verdict: .reply, requestID: "req-3",
                                                sessionID: "", text: "run the tests first"))
        let body = transport.lastBody()
        XCTAssertEqual(body["decision"] as? String, "deny",
                       "the server has no separate 'steer' verdict")
        XCTAssertEqual(body["message"] as? String, "run the tests first")
    }

    func testAVerdictWithNoRequestIdPostsNothing() async {
        let (api, transport) = JarvisAPI.mocked()
        let (handler, _) = makeHandler(api)
        await handler.handle(NotificationAction(verdict: .allow, requestID: "",
                                                sessionID: "", text: ""))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTappingTheBodyRoutesToTheSessionInsteadOfPosting() async {
        let (api, transport) = JarvisAPI.mocked()
        let (handler, router) = makeHandler(api)
        await handler.handle(NotificationAction(verdict: .open, requestID: "req-4",
                                                sessionID: "sess-4", text: ""))
        XCTAssertTrue(transport.requests.isEmpty, "the in-app card takes the verdict")
        XCTAssertEqual(router.selectedTab, .coding)
    }

    func testADeferredActionTapEnqueuesTheSkill() async {
        let (api, _) = JarvisAPI.mocked()
        let pending = PendingActions()
        let (handler, _) = makeHandler(api, pending: pending)
        let payload = notificationActionPayload(skill: "open_app", args: ["app": "maps"])

        let recovered = await handler.handle(
            NotificationAction(verdict: .open, requestID: "", sessionID: "",
                               text: "", deferredPayload: payload))

        XCTAssertEqual(recovered, "open_app")
        XCTAssertEqual(pending.count, 1)
    }

    func testAFailedVerdictPostIsSwallowed() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "boom"], status: 500)
        let (handler, _) = makeHandler(api)
        await handler.handle(NotificationAction(verdict: .allow, requestID: "req-5",
                                                sessionID: "", text: ""))
        XCTAssertEqual(transport.requests.count, 1, "the in-app card is the retry path")
    }

    // MARK: Categories

    #if canImport(UserNotifications)
    func testThePermissionCategoryCarriesAllThreeActions() {
        let categories = NotificationCategories.all()
        guard let category = categories.first(where: {
            $0.identifier == NotificationCategories.permissionApproval
        }) else { return XCTFail("PERMISSION_APPROVAL category missing") }
        XCTAssertEqual(category.actions.map(\.identifier),
                       [NotificationAction.Identifier.approve,
                        NotificationAction.Identifier.deny,
                        NotificationAction.Identifier.reply])
    }
    #endif

    // MARK: - A verdict that never reached the server (silent-failures H9)

    /// The tap dismissed the banner, so a swallowed failure looks exactly like
    /// an approval that went through — while the coding session sits waiting
    /// forever. The user has to be told, and the request has to stay answerable.
    func testAFailedVerdictRaisesAFollowUpBanner() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "nope"], status: 500)
        let notifier = MockNotifier()
        let (handler, _) = makeHandler(api, notifier: notifier)

        await handler.handle(NotificationAction(verdict: .allow, requestID: "req-1",
                                                sessionID: "sess-1", text: ""))

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNotNil(handler.lastVerdictError)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted[0].identifier,
                       NotificationActionHandler.verdictFailureIdentifier)
        XCTAssertEqual(notifier.posted[0].title, "Couldn't send your decision")
        XCTAssertTrue(notifier.posted[0].body.contains("Allow"),
                      "the banner has to say WHICH decision was lost")
    }

    func testAVerdictThatLandsRaisesNothing() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let notifier = MockNotifier()
        let (handler, _) = makeHandler(api, notifier: notifier)

        await handler.handle(NotificationAction(verdict: .deny, requestID: "req-1"))

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(handler.lastVerdictError)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    /// Notifications being off is why the verdict banner cannot be the only
    /// signal — it must not crash or wedge the handler when it too is refused.
    func testAFailedVerdictSurvivesARefusedFollowUpBanner() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "nope"], status: 500)
        let notifier = MockNotifier(granted: false)
        let (handler, _) = makeHandler(api, notifier: notifier)

        await handler.handle(NotificationAction(verdict: .reply, requestID: "req-1", text: "no"))

        XCTAssertNotNil(handler.lastVerdictError)
        XCTAssertTrue(notifier.posted.isEmpty)
    }
}
