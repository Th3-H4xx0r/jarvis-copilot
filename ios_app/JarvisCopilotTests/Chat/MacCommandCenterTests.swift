import XCTest
@testable import JarvisCopilot

/// The Mac's Command Center replies (MacControls.swift on the Mac) read into the
/// phone's state: switches, sliders, displays, apps; missing fields stay unknown.
final class MacCommandCenterTests: XCTestCase {
    func testStateReadsEverySwitch() {
        let s = MacControlState(json: [
            "t": "cc_state", "wifi": true, "wifi_name": "Home", "bluetooth": false, "dark": true,
            "stage": false, "volume": 42, "muted": false, "brightness": 0.75, "locked": true,
            "now": ["title": "Song", "artist": "Band", "playing": true],
            "displays": [["id": 1, "name": "Built-in Retina Display", "main": true],
                         ["id": 7, "name": "LG UltraFine", "main": false]],
            "display": 7,
        ])
        XCTAssertEqual(s.wifi, true)
        XCTAssertEqual(s.wifiName, "Home")
        XCTAssertEqual(s.bluetooth, false)
        XCTAssertEqual(s.volume, 42)
        XCTAssertEqual(s.brightness, 0.75)
        XCTAssertEqual(s.locked, true)
        XCTAssertEqual(s.nowTitle, "Song")
        XCTAssertEqual(s.nowPlaying, true)
        XCTAssertEqual(s.displays.map(\.id), [1, 7])
        XCTAssertEqual(s.displays.map(\.shortName), ["Built-in", "LG UltraFine"])
        XCTAssertEqual(s.display, 7)
    }

    func testMissingFieldsStayUnknown() {
        let s = MacControlState(json: ["t": "cc_state"])
        XCTAssertNil(s.wifi)
        XCTAssertNil(s.brightness)   // an external display: no brightness slider
        XCTAssertTrue(s.displays.isEmpty)
        XCTAssertEqual(MacControlState.onOff(nil), "—")
        XCTAssertEqual(MacControlState.onOff(true, on: "Home"), "Home")
        XCTAssertEqual(MacControlState.onOff(false), "Off")
    }

    func testAppsNeedPidAndName() {
        let apps = [["pid": 12, "name": "Safari", "bundle": "com.apple.Safari", "active": true],
                    ["name": "no pid"]].compactMap(MacApp.init(json:))
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.active, true)
        XCTAssertEqual(apps.first?.bundle, "com.apple.Safari")
    }
}
