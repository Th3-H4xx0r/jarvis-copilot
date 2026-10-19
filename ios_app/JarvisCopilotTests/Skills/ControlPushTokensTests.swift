import XCTest
@testable import JarvisCopilot

/// Control Center's refresh-push tokens: filed by the widget, sent on by the app only when they change.
@MainActor
final class ControlPushTokensTests: XCTestCase {

    private var defaults: UserDefaults!
    private var current: TokenBox!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ControlPushTokensTests-\(UUID().uuidString)")
        current = TokenBox()
    }

    private func uploader() -> ControlPushTokenUploader {
        let box = current!
        return ControlPushTokenUploader(defaults: defaults,
                                        tokens: { box.tokens },
                                        post: { tokens in
                                            box.posted.append(tokens)
                                            return box.ok
                                        })
    }

    func testTokensAreFiledAsHexSortedWithoutRepeats() {
        ControlPushTokens.save([Data([0xAB, 0x01]), Data([0x00, 0xFF]), Data([0xAB, 0x01])], defaults: defaults)
        XCTAssertEqual(ControlPushTokens.load(defaults: defaults), ["00ff", "ab01"])
        ControlPushTokens.save([], defaults: defaults)
        XCTAssertEqual(ControlPushTokens.load(defaults: defaults), [], "the set is replaced, not added to")
    }

    func testSentOnlyWhenTheyChange() async {
        let u = uploader()
        current.tokens = ["bb", "aa"]
        await u.uploadIfChanged()
        await u.uploadIfChanged()
        current.tokens = ["aa", "bb", "aa"]
        await u.uploadIfChanged()
        current.tokens = ["aa", "cc"]
        await u.uploadIfChanged()
        XCTAssertEqual(current.posted, [["aa", "bb"], ["aa", "cc"]])
    }

    func testAFailedSendGoesAgainNextTime() async {
        let u = uploader()
        current.tokens = ["aa"]
        current.ok = false
        await u.uploadIfChanged()
        current.ok = true
        await u.uploadIfChanged()
        await u.uploadIfChanged()
        XCTAssertEqual(current.posted, [["aa"], ["aa"]])
    }

    func testResentAfterADayInCaseTheServerLostThem() async {
        let u = uploader()
        current.tokens = ["aa"]
        let now = Date()
        await u.uploadIfChanged(now: now)
        await u.uploadIfChanged(now: now.addingTimeInterval(3600))
        await u.uploadIfChanged(now: now.addingTimeInterval(ControlPushTokenUploader.resendAfter + 60))
        XCTAssertEqual(current.posted.count, 2)
    }

    func testNothingToSendUntilThereIsAToken_thenAnEmptySetClearsTheServer() async {
        let u = uploader()
        await u.uploadIfChanged()
        XCTAssertTrue(current.posted.isEmpty)
        current.tokens = ["aa"]
        await u.uploadIfChanged()
        current.tokens = []
        await u.uploadIfChanged()
        XCTAssertEqual(current.posted, [["aa"], []])
    }
}

@MainActor
final class TokenBox {
    var tokens: [String] = []
    var posted: [[String]] = []
    var ok = true
}
