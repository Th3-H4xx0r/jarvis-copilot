import XCTest
@testable import JarvisCopilot

final class GlassesMusicRouteTests: XCTestCase {
    func testGenericPlayUsesNativeGlassesRoute() {
        XCTAssertEqual(GlassesMusicRoute.resolve(skill: "media_control", args: ["action": "play"], connected: true, chatOpen: false), .resume)
        XCTAssertEqual(GlassesMusicRoute.resolve(skill: "media_control", args: ["action": "toggle"], connected: true, chatOpen: true), .resume)
    }
    func testDisconnectedChatDoesNotFallBackToShortcut() {
        XCTAssertEqual(GlassesMusicRoute.resolve(skill: "media_control", args: ["action": "play"], connected: false, chatOpen: true), .resume)
    }
    func testDirectMediaShortcutDuringChatUsesNativeRoute() {
        XCTAssertEqual(GlassesMusicRoute.resolve(skill: "run_shortcut", args: ["name": "JC Play Pause"], connected: true, chatOpen: true), .resume)
    }
    func testMediaShortcutsBlockedWhileGlassesConnected() {
        for name in ["JC Play Pause", "JC Next Track", "JC Previous Track"] {
            XCTAssertEqual(GlassesMusicRoute.resolve(skill: "run_shortcut", args: ["name": name], connected: true, chatOpen: false), .rejectShortcut)
        }
    }
    func testUnrelatedPhoneActionsAreUnchanged() {
        XCTAssertNil(GlassesMusicRoute.resolve(skill: "media_control", args: ["action": "play"], connected: false, chatOpen: false))
        XCTAssertNil(GlassesMusicRoute.resolve(skill: "media_control", args: ["action": "status"], connected: true, chatOpen: true))
        XCTAssertNil(GlassesMusicRoute.resolve(skill: "run_shortcut", args: ["name": "JC Focus"], connected: true, chatOpen: true))
    }
}
