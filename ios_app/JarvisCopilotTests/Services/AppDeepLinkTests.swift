import Foundation
import XCTest
@testable import JarvisCopilot

/// The `jarviscopilot://` routing table — the Flutter client's
/// `AppDelegate.handleIncomingURL` plus the pair channel, now one pure parser.
@MainActor
final class AppDeepLinkTests: XCTestCase {

    private func parse(_ text: String) -> AppDeepLink? {
        guard let url = URL(string: text) else { return nil }
        return AppDeepLink.parse(url)
    }

    // MARK: Parsing

    func testVoiceRoute() {
        XCTAssertEqual(parse("jarviscopilot://voice"), .voice)
        XCTAssertEqual(parse("JARVISCOPILOT://VOICE"), .voice, "the scheme and host are case-insensitive")
    }

    func testChatRouteWithAndWithoutASession() {
        XCTAssertEqual(parse("jarviscopilot://chat"), .chat(session: nil))
        XCTAssertEqual(parse("jarviscopilot://chat?session=abc123"), .chat(session: "abc123"))
        XCTAssertEqual(parse("jarviscopilot://chat?session="), .chat(session: nil),
                       "an empty session id means 'no session', not a session called ''")
        XCTAssertEqual(parse("jarviscopilot://chat?session=%20%20"), .chat(session: nil))
    }

    func testCodingRouteWithAndWithoutASession() {
        XCTAssertEqual(parse("jarviscopilot://coding"), .coding(session: nil))
        XCTAssertEqual(parse("jarviscopilot://coding?session=s-9"), .coding(session: "s-9"))
        XCTAssertEqual(parse("jarviscopilot://coding?other=1"), .coding(session: nil))
    }

    func testIslandRoute() {
        XCTAssertEqual(parse("jarviscopilot://island"), .island)
        XCTAssertEqual(parse("jarviscopilot://designs"), .island)
    }

    func testShortcutCallbacksAreRecognisedButNotRouted() {
        XCTAssertEqual(parse("jarviscopilot://shortcut-result/sc1?result=hi"), .shortcutCallback)
        XCTAssertEqual(parse("jarviscopilot://shortcut-error/sc1?errorMessage=nope"), .shortcutCallback)
    }

    func testAnythingElseOnOurSchemeIsAPairingLink() {
        let url = URL(string: "jarviscopilot://pair?server=https://x&code=123")!
        XCTAssertEqual(AppDeepLink.parse(url), .pair(url))
    }

    func testMalformedAndForeignURLsAreNotOurs() {
        XCTAssertNil(parse("https://example.com/voice"))
        XCTAssertNil(parse("jarviscopilot://voice"), "the Flutter client's scheme is not ours")
        XCTAssertNil(parse("jarviscopilot:///voice"), "no host at all is malformed")
        XCTAssertNil(parse("jarviscopilot:"))
        XCTAssertNil(parse("mailto:someone@example.com"))
    }

    // MARK: Routing

    private func router() -> (AppDeepLinkRouter, AppRouter, DeepLinkTargets) {
        let appRouter = AppRouter()
        let targets = DeepLinkTargets()
        return (AppDeepLinkRouter(router: appRouter, targets: targets), appRouter, targets)
    }

    func testVoiceLinkLatchesAVoiceLaunch() {
        let (deepLinks, appRouter, _) = router()
        XCTAssertTrue(deepLinks.open(.voice))
        XCTAssertEqual(appRouter.selectedTab, .voice)
        XCTAssertTrue(appRouter.voiceLaunchRequested)
    }

    func testChatLinkSelectsTheTabAndLatchesTheSession() {
        let (deepLinks, appRouter, targets) = router()
        XCTAssertTrue(deepLinks.open(.chat(session: "abc")))
        XCTAssertEqual(appRouter.selectedTab, .chat)
        XCTAssertEqual(targets.chatSession, "abc")
        XCTAssertEqual(targets.consumeChat(), "abc")
        XCTAssertNil(targets.consumeChat(), "the latch is taken exactly once")
    }

    func testCodingLinkSelectsTheTabAndLatchesTheSession() {
        let (deepLinks, appRouter, targets) = router()
        XCTAssertTrue(deepLinks.open(.coding(session: "s1")))
        XCTAssertEqual(appRouter.selectedTab, .coding)
        XCTAssertEqual(targets.consumeCoding(), "s1")
    }

    func testIslandLinkOpensMoreAndNeverFallsThroughToPairing() {
        let (deepLinks, appRouter, _) = router()
        XCTAssertTrue(deepLinks.open(.island))
        XCTAssertEqual(appRouter.selectedTab, .more)
    }

    func testPairAndShortcutLinksAreLeftToTheirOwners() {
        let (deepLinks, appRouter, _) = router()
        let url = URL(string: "jarviscopilot://pair?code=1")!
        XCTAssertFalse(deepLinks.open(.pair(url)))
        XCTAssertFalse(deepLinks.open(.shortcutCallback))
        XCTAssertEqual(appRouter.selectedTab, .chat, "neither is navigation")
    }

    func testTargetGenerationBumpsSoARepeatedIdStillFires() {
        let targets = DeepLinkTargets()
        targets.requestCoding(session: "s1")
        let first = targets.generation
        _ = targets.consumeCoding()
        targets.requestCoding(session: "s1")
        XCTAssertEqual(targets.generation, first + 1)
    }
}
