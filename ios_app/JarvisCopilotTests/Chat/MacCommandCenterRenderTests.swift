import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Renders the Command Center and the landscape viewer to /tmp/ringshots, to look at
/// before they reach the phone.
@MainActor
final class MacCommandCenterRenderTests: XCTestCase {
    private func session() -> MacScreenSession {
        let s = MacScreenSession(shareID: "preview")
        s.receivedForTesting([
            "t": "cc_state", "wifi": true, "wifi_name": "Luke I am your router", "bluetooth": true, "dark": true,
            "stage": false, "volume": 40, "muted": false, "brightness": 0.6, "locked": false,
            "now": ["title": "Midnight City", "artist": "M83", "playing": true],
            "displays": [["id": 1, "name": "Built-in Retina Display", "main": true],
                         ["id": 2, "name": "Studio Display", "main": false]],
            "display": 1,
        ])
        s.receivedForTesting(["t": "cc_apps", "apps": [
            ["pid": 1, "name": "Finder", "bundle": "a", "active": false],
            ["pid": 2, "name": "Brave Browser", "bundle": "b", "active": true],
            ["pid": 3, "name": "Visual Studio Code", "bundle": "c", "active": false],
            ["pid": 4, "name": "Messages", "bundle": "d", "active": false],
            ["pid": 5, "name": "Music", "bundle": "e", "active": false],
        ]])
        return s
    }

    func testRenderCommandCenter() throws {
        try RenderHarness.write(MacCommandCenterSheet(session: session()),
                                size: CGSize(width: 402, height: 1500), name: "mac-command-center")
    }

    func testRenderLandscapeViewer() throws {
        try RenderHarness.write(MacScreenControlView(session: session(), closesShare: false),
                                size: CGSize(width: 874, height: 402), name: "mac-viewer-landscape")
        try RenderHarness.write(MacScreenControlView(session: session(), closesShare: false),
                                size: CGSize(width: 402, height: 874), name: "mac-viewer-portrait")
    }
}
