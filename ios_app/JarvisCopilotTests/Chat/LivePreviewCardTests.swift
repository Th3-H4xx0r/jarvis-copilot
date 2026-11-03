import XCTest
@testable import JarvisCopilot

final class LivePreviewCardTests: XCTestCase {
    private func tool(_ result: String) -> ToolInvocation {
        var t = ToolInvocation(name: "browser_navigate")
        t.result = result
        t.done = true
        return t
    }

    func testBrowserCardIDComesFromTheToolResult() {
        let t = tool(#"{"success": true, "url": "https://x.com", "card": {"kind": "browser_session", "session": "t_abc::chrome"}}"#)
        XCTAssertEqual(BrowserSessionCard.sessionID(in: t), "t_abc::chrome")
        XCTAssertNil(BrowserSessionCard.sessionID(in: tool(#"{"card": {"kind": "form", "form_id": "f1"}}"#)))
        XCTAssertNil(MacScreenCard.shareID(in: t))
    }

    func testMacCardIDComesFromTheToolResult() {
        let t = tool(#"{"ok": true, "card": {"kind": "mac_screen", "share": "sh_42"}}"#)
        XCTAssertEqual(MacScreenCard.shareID(in: t), "sh_42")
        XCTAssertNil(BrowserSessionCard.sessionID(in: t))
    }

    func testBrowserSessionDecodesTheContract() {
        let s = BrowserSession(json: [
            "id": "t1", "engine": "cloud", "provider_name": "Steel", "status": "running",
            "url": "https://www.example.com/a", "title": "", "live_url": "https://live.steel.dev/x",
            "takeover": true, "replay_status": "recording", "cloud_ready": true,
        ])
        XCTAssertEqual(s.engineLabel, "Cloud · Steel")
        XCTAssertEqual(s.host, "www.example.com")
        XCTAssertTrue(s.isRunning)
        XCTAssertTrue(s.takeover)
        XCTAssertEqual(s.liveURL?.host(), "live.steel.dev")
        XCTAssertEqual(BrowserSession(json: ["engine": "lightpanda"]).engineLabel, "Lightpanda")
        XCTAssertEqual(BrowserSession(json: ["engine": "chrome"]).engineLabel, "Server Chrome")
    }

    func testTapsMapOntoTheMacPictureNotTheLetterbox() throws {
        // A 16:10 Mac picture in a tall phone frame: bars above and below.
        let video = CGSize(width: 1600, height: 1000)
        let frame = CGSize(width: 400, height: 800)
        let rect = macScreenContentRect(video: video, in: frame)
        XCTAssertEqual(rect.width, 400, accuracy: 0.01)
        XCTAssertEqual(rect.height, 250, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 275, accuracy: 0.01)
        let centre = try XCTUnwrap(macScreenNormalised(CGPoint(x: 200, y: 400), video: video, in: frame))
        XCTAssertEqual(centre.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(centre.y, 0.5, accuracy: 0.001)
        XCTAssertNil(macScreenNormalised(CGPoint(x: 200, y: 100), video: video, in: frame), "a tap on the bar")
    }
}
