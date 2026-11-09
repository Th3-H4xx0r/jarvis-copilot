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

    private func pins(_ items: [MacControlItem]) -> MacControlPinsModel {
        let name = "MacCommandCenterRenderTests.\(UUID().uuidString)"
        let model = MacControlPinsModel(defaults: UserDefaults(suiteName: name)!)
        model.update { $0 = MacControlPins(pinned: items.map(\.rawValue)) }
        return model
    }

    func testRenderPinnedStripAndEditor() throws {
        let s = session()
        let model = pins([.nowPlaying, .sound, .wifi, .dark, .lock, .keepAwake, .missionControl])
        try RenderHarness.write(VStack(spacing: 0) {
            MacControlStrip(session: s, model: model)
            Divider()
            MacControlStrip(session: s, model: pins([]))
            Spacer()
        }.background(Color.black), size: CGSize(width: 402, height: 200), name: "mac-pinned-strip")
        try RenderHarness.write(MacControlStrip(session: s, layout: .column, model: model).frame(width: 270),
                                size: CGSize(width: 270, height: 520), name: "mac-pinned-column")
        try RenderHarness.write(MacControlPinsEditor(model: model),
                                size: CGSize(width: 402, height: 874), name: "mac-pins-editor")
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
