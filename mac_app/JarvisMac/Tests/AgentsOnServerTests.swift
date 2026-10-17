import XCTest
@testable import Jarvis

/// Sessions this Mac handed to the server while it slept, and the sleep/wake
/// signal that makes that possible.
final class AgentsOnServerTests: XCTestCase {

    func testPowerMessagesTellJcClientAboutSleepAndWake() {
        XCTAssertEqual(PowerRelay.message("will_sleep")["type"] as? String, "power")
        XCTAssertEqual(PowerRelay.message("will_sleep")["event"] as? String, "will_sleep")
        XCTAssertEqual(PowerRelay.message("did_wake")["event"] as? String, "did_wake")
    }

    @MainActor
    func testMovedSessionsShowAsOnServerAndBringBackRemovesOne() {
        let model = AppModel()
        model.handle(["type": "moved", "sessions": [
            ["ckey": "claude|s1", "agent": "claude", "title": "Fix the router", "project": "app"],
            ["ckey": "codex|c1", "agent": "codex", "title": "", "project": "web"],
        ]])
        XCTAssertEqual(model.onServer.map(\.ckey), ["claude|s1", "codex|c1"])
        XCTAssertEqual(model.onServer[1].title, "web")   // no title: the project names it
        model.bringBack("claude|s1", link: nil)
        XCTAssertEqual(model.onServer.map(\.ckey), ["codex|c1"])
    }

    func testWillSleepWaitsForTheReplyButNeverHangs() {
        // The link is down here, so the reply is an immediate failure: the
        // will-sleep handler must come back at once instead of waiting it out.
        let link = JcLink()
        let started = Date()
        let answer = link.requestAndWait(PowerRelay.message("will_sleep"), timeout: 3)
        XCTAssertEqual(answer?["ok"] as? Bool, false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
