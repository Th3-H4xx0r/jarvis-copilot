import XCTest
@testable import JarvisCopilot

// MARK: - The reply dictionary the watch actually decodes

/// `AskResult.from` on the watch reads `replyText`, `expectsClip` and the error
/// string `not_configured`. The first port answered with `text` and
/// `notConfigured`, so every reply arrived blank and "sign in on your iPhone"
/// showed as "couldn't reach JarvisCopilot". These pin the contract.
final class WatchReplyContractTests: XCTestCase {
    func testTheKeysAreTheOnesTheWatchReads() {
        let reply = WatchBridge.reply(text: "Two degrees, sir.", sentClip: true)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["replyText"] as? String, "Two degrees, sir.")
        XCTAssertEqual(reply["expectsClip"] as? Bool, true)
        XCTAssertNil(reply["text"], "the watch never reads `text`")
    }

    func testAReplyWithoutAClipSaysSoSoTheWatchSpeaksItItself() {
        let reply = WatchBridge.reply(text: "Done.", sentClip: false)
        XCTAssertEqual(reply["expectsClip"] as? Bool, false)
    }

    func testTheNotConfiguredErrorUsesTheWatchsSpelling() {
        let reply = WatchBridge.failure(.notConfigured)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "not_configured",
                       "camelCase fell through to the generic network error")
    }

    func testANetworkFailureCarriesItsDetail() {
        let reply = WatchBridge.failure(.network("no route"))
        XCTAssertEqual(reply["error"] as? String, "network")
        XCTAssertEqual(reply["detail"] as? String, "no route")
    }
}
